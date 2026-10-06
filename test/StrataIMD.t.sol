// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {StrataIMD} from "../src/StrataIMD.sol";

/// @dev Test-only factory to exercise the same immediate-caller semantics as a CREATE2 launch.
contract TokenFactoryFixture {
    function deploy(bytes32 salt) external returns (StrataIMD) {
        return new StrataIMD{salt: salt}();
    }
}

contract StrataIMDTest is Test {
    uint256 private constant SUPPLY = 1_000_000_000 * 10 ** 18;
    address private constant DEPLOYER = address(0xD3);
    address private constant ALICE = address(0xA11CE);
    address private constant BOB = address(0xB0B);
    address private constant SPENDER = address(0x5EED);

    StrataIMD private token;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function setUp() public {
        vm.prank(DEPLOYER);
        token = new StrataIMD();
    }

    function testMetadataAndInitialSupply() public view {
        assertEq(token.name(), "StrataIMD");
        assertEq(token.symbol(), "STRATA");
        assertEq(token.decimals(), 18);
        assertEq(token.INITIAL_SUPPLY(), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(DEPLOYER), SUPPLY);
        assertEq(token.balanceOf(address(this)), 0);
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.allowance(DEPLOYER, SPENDER), 0);
    }

    function testConstructorEmitsMintEvent() public {
        vm.expectEmit(true, true, false, true);
        emit Transfer(address(0), DEPLOYER, SUPPLY);
        vm.prank(DEPLOYER);
        new StrataIMD();
    }

    function testCreate2MintsAllSupplyToFactory() public {
        TokenFactoryFixture factory = new TokenFactoryFixture();
        bytes32 salt = keccak256("StrataIMD launch fixture");
        address expected = address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(bytes1(0xff), address(factory), salt, keccak256(type(StrataIMD).creationCode))
                    )
                )
            )
        );
        vm.prank(ALICE);
        StrataIMD launched = factory.deploy(salt);

        assertEq(address(launched), expected);
        assertEq(launched.balanceOf(address(factory)), SUPPLY);
        assertEq(launched.balanceOf(ALICE), 0);
        assertEq(launched.totalSupply(), SUPPLY);
    }

    function testLaunchTransferAccountingHasNoFees() public {
        TokenFactoryFixture factory = new TokenFactoryFixture();
        StrataIMD launched = factory.deploy(bytes32(uint256(1)));
        address distributor = address(0xD157);
        address poolManager = address(0x9001);
        address requester = address(0x9002);
        uint256 swarmShare = SUPPLY / 10;
        // An illustrative allocation only: actual pool economics belong to the launch configuration.
        uint256 poolShare = SUPPLY / 2;

        vm.startPrank(address(factory));
        assertTrue(launched.transfer(distributor, swarmShare));
        assertTrue(launched.transfer(poolManager, poolShare));
        assertTrue(launched.transfer(requester, SUPPLY - swarmShare - poolShare));
        vm.stopPrank();
        assertEq(launched.balanceOf(address(factory)), 0);
        assertEq(launched.balanceOf(distributor), swarmShare);
        assertEq(launched.balanceOf(poolManager), poolShare);
        assertEq(launched.balanceOf(requester), SUPPLY - swarmShare - poolShare);

        vm.prank(distributor);
        assertTrue(launched.transfer(ALICE, swarmShare));
        assertEq(launched.balanceOf(distributor), 0);
        assertEq(launched.balanceOf(ALICE), swarmShare);

        // Exercise the token side of a buy and sell; this is not a PoolManager swap simulation.
        vm.prank(poolManager);
        assertTrue(launched.transfer(BOB, 100 ether));
        assertEq(launched.balanceOf(BOB), 100 ether);
        vm.prank(BOB);
        assertTrue(launched.transfer(poolManager, 100 ether));
        assertEq(launched.balanceOf(BOB), 0);
        assertEq(launched.balanceOf(poolManager), poolShare);
        assertEq(launched.totalSupply(), SUPPLY);
    }

    function testTransferEmitsEventAndDeliversExactAmount() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(DEPLOYER, ALICE, 123 ether + 1);
        vm.prank(DEPLOYER);
        assertTrue(token.transfer(ALICE, 123 ether + 1));
        assertEq(token.balanceOf(ALICE), 123 ether + 1);
        assertEq(token.balanceOf(DEPLOYER), SUPPLY - 123 ether - 1);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testTransferEntireSupply() public {
        vm.prank(DEPLOYER);
        assertTrue(token.transfer(ALICE, SUPPLY));
        assertEq(token.balanceOf(DEPLOYER), 0);
        assertEq(token.balanceOf(ALICE), SUPPLY);
    }

    function testZeroTransferFromEmptyAccountEmitsEvent() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(ALICE, BOB, 0);
        vm.prank(ALICE);
        assertTrue(token.transfer(BOB, 0));
        assertEq(token.balanceOf(ALICE), 0);
        assertEq(token.balanceOf(BOB), 0);
    }

    function testSelfTransferPreservesBalance() public {
        vm.prank(DEPLOYER);
        assertTrue(token.transfer(DEPLOYER, SUPPLY));
        assertEq(token.balanceOf(DEPLOYER), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testApproveOverwriteAndRevoke() public {
        vm.startPrank(DEPLOYER);
        vm.expectEmit(true, true, false, true, address(token));
        emit Approval(DEPLOYER, SPENDER, 100 ether);
        assertTrue(token.approve(SPENDER, 100 ether));
        assertEq(token.allowance(DEPLOYER, SPENDER), 100 ether);
        assertTrue(token.approve(SPENDER, 7 ether));
        assertEq(token.allowance(DEPLOYER, SPENDER), 7 ether);
        assertTrue(token.approve(SPENDER, 0));
        vm.stopPrank();
        assertEq(token.allowance(DEPLOYER, SPENDER), 0);
        assertEq(token.balanceOf(DEPLOYER), SUPPLY);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, SPENDER, 0, 1));
        vm.prank(SPENDER);
        token.transferFrom(DEPLOYER, ALICE, 1);
    }

    function testTransferFromConsumesFiniteAllowanceAndEmitsTransfer() public {
        vm.prank(DEPLOYER);
        token.approve(SPENDER, 100 ether);
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(DEPLOYER, ALICE, 40 ether);
        vm.prank(SPENDER);
        assertTrue(token.transferFrom(DEPLOYER, ALICE, 40 ether));
        assertEq(token.allowance(DEPLOYER, SPENDER), 60 ether);
        assertEq(token.balanceOf(DEPLOYER), SUPPLY - 40 ether);
        assertEq(token.balanceOf(ALICE), 40 ether);
        vm.prank(SPENDER);
        assertTrue(token.transferFrom(DEPLOYER, BOB, 60 ether));
        assertEq(token.allowance(DEPLOYER, SPENDER), 0);
        assertEq(token.balanceOf(BOB), 60 ether);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testInfiniteAllowanceIsNotDecreased() public {
        vm.prank(DEPLOYER);
        token.approve(SPENDER, type(uint256).max);
        vm.prank(SPENDER);
        assertTrue(token.transferFrom(DEPLOYER, ALICE, SUPPLY));
        assertEq(token.allowance(DEPLOYER, SPENDER), type(uint256).max);
        assertEq(token.balanceOf(ALICE), SUPPLY);
    }

    function testTransferFromToSelfConsumesAllowanceWithoutChangingBalance() public {
        vm.prank(DEPLOYER);
        token.approve(SPENDER, 1 ether);
        vm.prank(SPENDER);
        assertTrue(token.transferFrom(DEPLOYER, DEPLOYER, 1 ether));
        assertEq(token.allowance(DEPLOYER, SPENDER), 0);
        assertEq(token.balanceOf(DEPLOYER), SUPPLY);
    }

    function testZeroTransferFromNeedsNoAllowance() public {
        vm.prank(SPENDER);
        assertTrue(token.transferFrom(ALICE, BOB, 0));
        assertEq(token.allowance(ALICE, SPENDER), 0);
        assertEq(token.balanceOf(BOB), 0);
    }

    function testTransferRejectsZeroRecipientEvenForZeroAmount() public {
        vm.startPrank(DEPLOYER);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 1);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 0);
        vm.stopPrank();
        assertEq(token.balanceOf(DEPLOYER), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testApproveRejectsZeroSpender() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        vm.prank(DEPLOYER);
        token.approve(address(0), 1);
        assertEq(token.allowance(DEPLOYER, address(0)), 0);
    }

    function testTransferFromRejectsZeroSender() public {
        // Allowance spending validates its owner before the transfer validates its sender.
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidApprover.selector, address(0)));
        vm.prank(SPENDER);
        token.transferFrom(address(0), ALICE, 0);
        assertEq(token.allowance(address(0), SPENDER), 0);
        assertEq(token.balanceOf(ALICE), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testTransferFromInvalidRecipientRollsBackAllowance() public {
        vm.prank(DEPLOYER);
        token.approve(SPENDER, 10);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(SPENDER);
        token.transferFrom(DEPLOYER, address(0), 10);
        assertEq(token.allowance(DEPLOYER, SPENDER), 10);
        assertEq(token.balanceOf(DEPLOYER), SUPPLY);
    }

    function testTransferFromInsufficientBalanceRollsBackAllowance() public {
        vm.prank(ALICE);
        token.approve(SPENDER, 10);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, ALICE, 0, 10));
        vm.prank(SPENDER);
        token.transferFrom(ALICE, BOB, 10);
        assertEq(token.allowance(ALICE, SPENDER), 10);
        assertEq(token.balanceOf(ALICE), 0);
        assertEq(token.balanceOf(BOB), 0);
    }

    function testDeployerCannotSpendHolderFundsWithoutApproval() public {
        vm.prank(DEPLOYER);
        token.transfer(ALICE, 10 ether);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, DEPLOYER, 0, 1));
        vm.prank(DEPLOYER);
        token.transferFrom(ALICE, DEPLOYER, 1);
        assertEq(token.balanceOf(ALICE), 10 ether);
    }

    function testNoMintBurnOrAdministrativeSelectors() public {
        vm.prank(DEPLOYER);
        token.transfer(ALICE, 10 ether);
        string[24] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "mint()",
            "issue(uint256)",
            "setOwner(address)",
            "transferOwnership(address)",
            "upgradeTo(address)",
            "initialize(address)",
            "unpause()",
            "setMinter(address)",
            "pause()",
            "blacklist(address)",
            "blocklist(address)",
            "freeze(address)",
            "freezeAccount(address)",
            "setBlacklist(address,bool)",
            "setBlocked(address,bool)",
            "lock(address)",
            "disableTransfers()",
            "setTransfersEnabled(bool)",
            "burnFrom(address,uint256)",
            "seize(address)",
            "burn(uint256)",
            "initialize()"
        ];
        for (uint256 i; i < signatures.length; ++i) {
            bytes memory data = abi.encodeWithSignature(signatures[i], ALICE, uint256(1));
            vm.prank(DEPLOYER);
            (bool deployerSucceeded,) = address(token).call(data);
            assertFalse(deployerSucceeded, signatures[i]);
            vm.prank(BOB);
            (bool strangerSucceeded,) = address(token).call(data);
            assertFalse(strangerSucceeded, signatures[i]);
        }
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(DEPLOYER), SUPPLY - 10 ether);
        assertEq(token.balanceOf(ALICE), 10 ether);
        vm.prank(ALICE);
        assertTrue(token.transfer(BOB, 10 ether));
        assertEq(token.balanceOf(BOB), 10 ether);
    }

    function testRuntimeHasNoForbiddenOpcodes() public view {
        bytes memory runtime = address(token).code;
        assertGt(runtime.length, 0);
        assertLe(runtime.length, 24_576);
        for (uint256 i; i < runtime.length; ++i) {
            uint8 op = uint8(runtime[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff, "forbidden opcode");
        }
    }

    function testFuzzTransferHasNoFee(address recipient, uint256 amount) public {
        vm.assume(recipient != address(0) && recipient != DEPLOYER);
        amount = bound(amount, 0, SUPPLY);
        vm.prank(DEPLOYER);
        assertTrue(token.transfer(recipient, amount));
        assertEq(token.balanceOf(recipient), amount);
        assertEq(token.balanceOf(DEPLOYER), SUPPLY - amount);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzzDelegatedTransferHasNoFee(uint256 approved, uint256 amount) public {
        approved = bound(approved, 0, SUPPLY);
        amount = bound(amount, 0, approved);
        vm.prank(DEPLOYER);
        token.approve(SPENDER, approved);
        vm.prank(SPENDER);
        assertTrue(token.transferFrom(DEPLOYER, ALICE, amount));
        assertEq(token.allowance(DEPLOYER, SPENDER), approved - amount);
        assertEq(token.balanceOf(ALICE), amount);
        assertEq(token.balanceOf(DEPLOYER), SUPPLY - amount);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzzTransferAboveBalanceReverts(uint256 amount) public {
        amount = bound(amount, SUPPLY + 1, type(uint256).max);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, DEPLOYER, SUPPLY, amount)
        );
        vm.prank(DEPLOYER);
        token.transfer(ALICE, amount);
        assertEq(token.balanceOf(DEPLOYER), SUPPLY);
        assertEq(token.balanceOf(ALICE), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzzTransferFromAboveAllowanceReverts(uint256 approved) public {
        approved = bound(approved, 0, SUPPLY - 1);
        vm.prank(DEPLOYER);
        token.approve(SPENDER, approved);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, SPENDER, approved, approved + 1)
        );
        vm.prank(SPENDER);
        token.transferFrom(DEPLOYER, ALICE, approved + 1);
        assertEq(token.allowance(DEPLOYER, SPENDER), approved);
        assertEq(token.balanceOf(DEPLOYER), SUPPLY);
        assertEq(token.balanceOf(ALICE), 0);
    }
}
