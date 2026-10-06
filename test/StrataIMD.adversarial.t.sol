// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {StrataIMD} from "../src/StrataIMD.sol";

/// @dev Complements the basic token suite with boundaries and authorization changes over time.
/// forge-config: default.fuzz.runs = 1000
contract StrataIMDAdversarialTest is Test {
    uint256 private constant SUPPLY = 1_000_000_000 * 10 ** 18;
    address private constant ALICE = address(0xA11CE);
    address private constant BOB = address(0xB0B);
    address private constant SPENDER = address(0x5EED);
    address private constant OTHER_SPENDER = address(0x5EED2);

    StrataIMD private token;

    event Transfer(address indexed from, address indexed to, uint256 value);

    function setUp() public {
        token = new StrataIMD();
    }

    function testOneWeiCanMoveAndBeSpentExactlyOnce() public {
        assertTrue(token.transfer(ALICE, 1));
        vm.prank(ALICE);
        assertTrue(token.approve(SPENDER, 1));
        vm.prank(SPENDER);
        assertTrue(token.transferFrom(ALICE, BOB, 1));

        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, SPENDER, 0, 1));
        vm.prank(SPENDER);
        token.transferFrom(ALICE, BOB, 1);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, ALICE, 0, 1));
        vm.prank(ALICE);
        token.transfer(BOB, 1);

        assertEq(token.balanceOf(BOB), 1);
        assertEq(token.balanceOf(ALICE), 0);
        assertEq(token.balanceOf(address(this)), SUPPLY - 1);
        assertEq(token.allowance(ALICE, SPENDER), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testMaximumTransferRevertsEvenToSelf() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector, address(this), SUPPLY, type(uint256).max
            )
        );
        token.transfer(ALICE, type(uint256).max);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector, address(this), SUPPLY, type(uint256).max
            )
        );
        token.transfer(address(this), type(uint256).max);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(ALICE), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testLargestFiniteAllowanceDecreasesOnEverySpend() public {
        assertTrue(token.approve(SPENDER, type(uint256).max - 1));
        vm.prank(SPENDER);
        assertTrue(token.transferFrom(address(this), ALICE, 1));
        assertEq(token.allowance(address(this), SPENDER), type(uint256).max - 2);
        vm.prank(SPENDER);
        assertTrue(token.transferFrom(address(this), BOB, SUPPLY - 1));
        assertEq(token.allowance(address(this), SPENDER), type(uint256).max - 1 - SUPPLY);
        assertEq(token.balanceOf(ALICE), 1);
        assertEq(token.balanceOf(BOB), SUPPLY - 1);
        assertEq(token.balanceOf(address(this)), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testMaximumDelegatedTransferCannotUseUnlimitedApprovalToCreateBalance() public {
        assertTrue(token.approve(SPENDER, type(uint256).max));
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector, address(this), SUPPLY, type(uint256).max
            )
        );
        vm.prank(SPENDER);
        token.transferFrom(address(this), ALICE, type(uint256).max);
        assertEq(token.allowance(address(this), SPENDER), type(uint256).max);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(ALICE), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testInfiniteApprovalCanBeRevokedAndReplacedAfterSpending() public {
        assertTrue(token.approve(SPENDER, type(uint256).max));
        vm.prank(SPENDER);
        assertTrue(token.transferFrom(address(this), ALICE, 1));
        assertEq(token.allowance(address(this), SPENDER), type(uint256).max);

        assertTrue(token.approve(SPENDER, 0));
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, SPENDER, 0, 1));
        vm.prank(SPENDER);
        token.transferFrom(address(this), ALICE, 1);

        assertTrue(token.approve(SPENDER, 2));
        vm.prank(SPENDER);
        assertTrue(token.transferFrom(address(this), ALICE, 2));
        assertEq(token.allowance(address(this), SPENDER), 0);
        assertEq(token.balanceOf(ALICE), 3);
        assertEq(token.balanceOf(address(this)), SUPPLY - 3);
    }

    function testZeroDelegatedTransferEmitsEventWithoutConsumingApproval() public {
        vm.prank(ALICE);
        assertTrue(token.approve(SPENDER, 7));
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(ALICE, BOB, 0);
        vm.prank(SPENDER);
        assertTrue(token.transferFrom(ALICE, BOB, 0));
        assertEq(token.allowance(ALICE, SPENDER), 7);
        assertEq(token.balanceOf(ALICE), 0);
        assertEq(token.balanceOf(BOB), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testZeroDelegatedTransferStillRejectsZeroRecipient() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(SPENDER);
        token.transferFrom(ALICE, address(0), 0);
        assertEq(token.allowance(ALICE, SPENDER), 0);
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzzApprovalsAreIndependentForEveryOwnerAndSpender(uint256 amount) public {
        amount = bound(amount, 1, SUPPLY / 2);
        assertTrue(token.transfer(ALICE, amount));
        assertTrue(token.transfer(BOB, amount));
        vm.prank(ALICE);
        assertTrue(token.approve(SPENDER, amount));
        vm.prank(ALICE);
        assertTrue(token.approve(OTHER_SPENDER, type(uint256).max));
        vm.prank(BOB);
        assertTrue(token.approve(SPENDER, amount));

        // Alice revokes one spender; Bob's grant and Alice's other spender remain valid.
        vm.prank(ALICE);
        assertTrue(token.approve(SPENDER, 0));
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, SPENDER, 0, amount));
        vm.prank(SPENDER);
        token.transferFrom(ALICE, address(this), amount);
        assertEq(token.balanceOf(ALICE), amount);
        assertEq(token.balanceOf(BOB), amount);
        assertEq(token.allowance(ALICE, OTHER_SPENDER), type(uint256).max);
        assertEq(token.allowance(BOB, SPENDER), amount);

        vm.prank(SPENDER);
        assertTrue(token.transferFrom(BOB, address(this), amount));
        vm.prank(OTHER_SPENDER);
        assertTrue(token.transferFrom(ALICE, address(this), amount));
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(ALICE), 0);
        assertEq(token.balanceOf(BOB), 0);
        assertEq(token.allowance(ALICE, SPENDER), 0);
        assertEq(token.allowance(ALICE, OTHER_SPENDER), type(uint256).max);
        assertEq(token.allowance(BOB, SPENDER), 0);
    }

    function testFuzzBalanceFailurePreservesFiniteApprovalForRetry(uint256 funded, uint256 approved) public {
        funded = bound(funded, 0, SUPPLY - 1);
        uint256 attempted = funded + 1;
        approved = bound(approved, attempted, type(uint256).max - 1);
        assertTrue(token.transfer(ALICE, funded));
        vm.prank(ALICE);
        assertTrue(token.approve(SPENDER, approved));

        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, ALICE, funded, attempted)
        );
        vm.prank(SPENDER);
        token.transferFrom(ALICE, BOB, attempted);
        assertEq(token.allowance(ALICE, SPENDER), approved);
        assertEq(token.balanceOf(ALICE), funded);
        assertEq(token.balanceOf(BOB), 0);

        // Funding the missing wei must make the exact same call succeed without reapproval.
        assertTrue(token.transfer(ALICE, 1));
        vm.prank(SPENDER);
        assertTrue(token.transferFrom(ALICE, BOB, attempted));
        assertEq(token.allowance(ALICE, SPENDER), approved - attempted);
        assertEq(token.balanceOf(ALICE), 0);
        assertEq(token.balanceOf(BOB), attempted);
        assertEq(token.balanceOf(address(this)), SUPPLY - attempted);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzzPartialSpendThenLowerApprovalLimitsFurtherSpending(uint256 original, uint256 spent, uint256 lower)
        public
    {
        original = bound(original, 2, SUPPLY);
        spent = bound(spent, 1, original - 1);
        lower = bound(lower, 0, original - spent - 1);
        assertTrue(token.approve(SPENDER, original));
        vm.prank(SPENDER);
        assertTrue(token.transferFrom(address(this), ALICE, spent));
        assertTrue(token.approve(SPENDER, lower));

        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, SPENDER, lower, lower + 1)
        );
        vm.prank(SPENDER);
        token.transferFrom(address(this), BOB, lower + 1);
        assertEq(token.allowance(address(this), SPENDER), lower);
        assertEq(token.balanceOf(ALICE), spent);
        assertEq(token.balanceOf(BOB), 0);

        vm.prank(SPENDER);
        assertTrue(token.transferFrom(address(this), BOB, lower));
        assertEq(token.allowance(address(this), SPENDER), 0);
        assertEq(token.balanceOf(BOB), lower);
        assertEq(token.balanceOf(address(this)), SUPPLY - spent - lower);
    }

    function testFuzzDirectAndDelegatedRoundTripIsLossless(uint256 amount, uint256 approved) public {
        amount = bound(amount, 0, SUPPLY);
        approved = bound(approved, amount, type(uint256).max);
        assertTrue(token.transfer(ALICE, amount));
        vm.prank(ALICE);
        assertTrue(token.approve(SPENDER, approved));
        vm.prank(SPENDER);
        assertTrue(token.transferFrom(ALICE, address(this), amount));

        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(ALICE), 0);
        assertEq(token.balanceOf(SPENDER), 0);
        assertEq(token.allowance(ALICE, SPENDER), approved == type(uint256).max ? approved : approved - amount);
        assertEq(token.totalSupply(), SUPPLY);
    }
}
