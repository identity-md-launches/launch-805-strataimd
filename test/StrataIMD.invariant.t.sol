// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {StrataIMD} from "../src/StrataIMD.sol";

/// @dev Closed set of holders makes conservation measurable across arbitrary operation sequences.
contract StrataIMDHandler is Test {
    StrataIMD private immutable token;
    address[4] public actors = [address(0x1000), address(0x2000), address(0x3000), address(0x4000)];

    // Record requested, successful operations independently of the token's returned state.
    mapping(address => uint256) public received;
    mapping(address => uint256) public sent;
    mapping(address => mapping(address => uint256)) public lastApproval;
    mapping(address => mapping(address => uint256)) public spentSinceApproval;

    constructor(StrataIMD token_) {
        token = token_;
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = actors[fromSeed % actors.length];
        address to = actors[toSeed % actors.length];
        uint256 fromBefore = token.balanceOf(from);
        uint256 toBefore = token.balanceOf(to);
        amount = bound(amount, 0, fromBefore);
        vm.prank(from);
        assertTrue(token.transfer(to, amount));
        _recordMovement(from, to, amount);
        _assertMovement(from, to, fromBefore, toBefore, amount);
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amount) external {
        address owner = actors[ownerSeed % actors.length];
        address spender = actors[spenderSeed % actors.length];
        _approve(owner, spender, amount);
    }

    function approveBoundary(uint256 ownerSeed, uint256 spenderSeed, uint8 mode) external {
        address owner = actors[ownerSeed % actors.length];
        address spender = actors[spenderSeed % actors.length];
        uint256 amount = mode % 3 == 0 ? 0 : (mode % 3 == 1 ? type(uint256).max : type(uint256).max - 1);
        _approve(owner, spender, amount);
    }

    function transferFrom(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed, uint256 amount) external {
        address owner = actors[ownerSeed % actors.length];
        address spender = actors[spenderSeed % actors.length];
        address to = actors[toSeed % actors.length];
        uint256 approved = token.allowance(owner, spender);
        uint256 ownerBefore = token.balanceOf(owner);
        uint256 toBefore = token.balanceOf(to);
        amount = bound(amount, 0, approved < ownerBefore ? approved : ownerBefore);
        vm.prank(spender);
        assertTrue(token.transferFrom(owner, to, amount));
        spentSinceApproval[owner][spender] += amount;
        _recordMovement(owner, to, amount);
        assertEq(token.allowance(owner, spender), approved == type(uint256).max ? approved : approved - amount);
        _assertMovement(owner, to, ownerBefore, toBefore, amount);
    }

    function rejectTransferAboveBalance(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = actors[fromSeed % actors.length];
        address to = actors[toSeed % actors.length];
        uint256 balance = token.balanceOf(from);
        amount = bound(amount, balance + 1, type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, from, balance, amount));
        vm.prank(from);
        token.transfer(to, amount);
        // No ghost update: the invariants require every balance and allowance to stay unchanged.
    }

    function rejectTransferFromAboveAllowance(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed) external {
        address owner = actors[ownerSeed % actors.length];
        address spender = actors[spenderSeed % actors.length];
        address to = actors[toSeed % actors.length];
        uint256 approved = token.allowance(owner, spender);
        if (approved == type(uint256).max) {
            // An unlimited approval must also be revocable after any prior sequence of spending.
            _approve(owner, spender, 0);
            approved = 0;
        }
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, approved, approved + 1)
        );
        vm.prank(spender);
        token.transferFrom(owner, to, approved + 1);
    }

    function rejectTransferFromAboveBalance(
        uint256 ownerSeed,
        uint256 spenderSeed,
        uint256 toSeed,
        uint256 amount,
        bool unlimited
    ) external {
        address owner = actors[ownerSeed % actors.length];
        address spender = actors[spenderSeed % actors.length];
        address to = actors[toSeed % actors.length];
        uint256 balance = token.balanceOf(owner);
        amount = bound(amount, balance + 1, type(uint256).max);
        _approve(owner, spender, unlimited ? type(uint256).max : amount);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, owner, balance, amount));
        vm.prank(spender);
        token.transferFrom(owner, to, amount);
        // In particular, spending the allowance before the balance check must be rolled back.
    }

    function rejectZeroRecipient(uint256 ownerSeed, uint256 spenderSeed, uint256 amount, bool delegated) external {
        address owner = actors[ownerSeed % actors.length];
        address spender = actors[spenderSeed % actors.length];
        amount = bound(amount, 0, token.balanceOf(owner));
        if (delegated) {
            _approve(owner, spender, amount);
            vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
            vm.prank(spender);
            token.transferFrom(owner, address(0), amount);
        } else {
            vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
            vm.prank(owner);
            token.transfer(address(0), amount);
        }
    }

    function _approve(address owner, address spender, uint256 amount) private {
        vm.prank(owner);
        assertTrue(token.approve(spender, amount));
        lastApproval[owner][spender] = amount;
        spentSinceApproval[owner][spender] = 0;
        assertEq(token.allowance(owner, spender), amount);
    }

    function _recordMovement(address from, address to, uint256 amount) private {
        sent[from] += amount;
        received[to] += amount;
    }

    function _assertMovement(address from, address to, uint256 fromBefore, uint256 toBefore, uint256 amount)
        private
        view
    {
        if (from == to) {
            assertEq(token.balanceOf(from), fromBefore);
        } else {
            assertEq(token.balanceOf(from), fromBefore - amount);
            assertEq(token.balanceOf(to), toBefore + amount);
        }
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 128
/// forge-config: default.invariant.fail-on-revert = true
contract StrataIMDInvariantTest is Test {
    uint256 private constant SUPPLY = 1_000_000_000 * 10 ** 18;
    StrataIMD private token;
    StrataIMDHandler private handler;

    function setUp() public {
        token = new StrataIMD();
        handler = new StrataIMDHandler(token);
        for (uint256 i; i < 4; ++i) {
            token.transfer(handler.actors(i), SUPPLY / 4);
        }

        bytes4[] memory selectors = new bytes4[](8);
        selectors[0] = StrataIMDHandler.transfer.selector;
        selectors[1] = StrataIMDHandler.approve.selector;
        selectors[2] = StrataIMDHandler.transferFrom.selector;
        selectors[3] = StrataIMDHandler.approveBoundary.selector;
        selectors[4] = StrataIMDHandler.rejectTransferAboveBalance.selector;
        selectors[5] = StrataIMDHandler.rejectTransferFromAboveAllowance.selector;
        selectors[6] = StrataIMDHandler.rejectTransferFromAboveBalance.selector;
        selectors[7] = StrataIMDHandler.rejectZeroRecipient.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function invariantSupplyAndBalancesAreConserved() public view {
        assertEq(token.totalSupply(), SUPPLY);
        uint256 sum;
        for (uint256 i; i < 4; ++i) {
            sum += token.balanceOf(handler.actors(i));
        }
        assertEq(sum, SUPPLY);
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.balanceOf(address(this)), 0);
        assertEq(token.balanceOf(address(handler)), 0);
    }

    /// @dev Conservation alone misses value taken from an unrelated holder or approval pair.
    function invariantBalancesAndAllowancesMatchAuthorizedOperations() public view {
        for (uint256 i; i < 4; ++i) {
            address owner = handler.actors(i);
            assertEq(token.balanceOf(owner) + handler.sent(owner), SUPPLY / 4 + handler.received(owner));
            for (uint256 j; j < 4; ++j) {
                address spender = handler.actors(j);
                uint256 approved = handler.lastApproval(owner, spender);
                uint256 remaining = token.allowance(owner, spender);
                if (approved == type(uint256).max) {
                    assertEq(remaining, type(uint256).max, "unlimited approval changed");
                } else {
                    assertEq(remaining + handler.spentSinceApproval(owner, spender), approved, "approval accounting");
                }
            }
        }
    }
}
