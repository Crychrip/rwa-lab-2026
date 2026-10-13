// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {MockUSDC} from "../../src/MockUSDC.sol";
import {ComplianceRegistry} from "../../src/ComplianceRegistry.sol";
import {TBillToken} from "../../src/TBillToken.sol";
import {TBillVault} from "../../src/TBillVault.sol";
import {MockPriceFeed} from "../../src/exercises/MockPriceFeed.sol";
import {MockTBillCustodian} from "../../src/exercises/MockTBillCustodian.sol";

/// @title Ex2 + Ex3 + Ex4 — three planks of the bridge: custody (a), attestation (b), admission (d)
/// @notice The bridge is how an off-chain asset becomes an on-chain token. Each exercise below
///         pulls on one plank and shows you what is holding the span up — and what is not.
///         The fourth plank, redemption (c), is the queue you write in Ex5.
///
///         Every `assertTrue(false, "TODO ...")` below is a placeholder. Write the real
///         assertion, watch the test go green, and that exercise is done.
///
///         Acceptance: make exercise (it should be red until you are finished)
///         Do not open test/TBill.t.sol — it contains the answers. Write yours first, and
///         only look once you are stuck.
contract BridgeTasksTest is Test {
    MockUSDC internal usdc;
    ComplianceRegistry internal compliance;
    MockPriceFeed internal feed;
    TBillToken internal tBill;
    MockTBillCustodian internal custodian;
    TBillVault internal vault;

    address internal admin = address(this);
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal attacker = makeAddr("attacker");

    uint256 internal constant PAR = 1e8;
    uint256 internal constant NAV_1_25 = 1.25e8;

    function setUp() public {
        usdc = new MockUSDC();
        compliance = new ComplianceRegistry(admin);
        feed = new MockPriceFeed(int256(PAR));
        tBill = new TBillToken(admin, compliance);
        custodian = new MockTBillCustodian(admin);
        vault = new TBillVault(usdc, tBill, feed, custodian, admin);

        tBill.grantRole(tBill.MINTER_ROLE(), address(vault));
        custodian.grantRole(custodian.CUSTODIAN_ROLE(), address(vault));

        compliance.setWhitelisted(admin, true);
        compliance.setWhitelisted(alice, true);
        compliance.setWhitelisted(bob, true);
    }

    /// @dev Given: pay `assets` of USDC and receive shares at today's NAV
    function _subscribe(address user, uint256 assets) internal {
        usdc.faucet(user, assets);
        vm.startPrank(user);
        usdc.approve(address(vault), assets);
        vault.subscribe(assets);
        vm.stopPrank();
    }

    // ==================================================================
    // Ex2 · plank (a) custody — the shares exist, the box may not
    // ==================================================================

    /// @dev Subscribe 1000 USDC at par, then look at both sides of the bridge at once: the
    ///      shares alice now holds, and what the custodian actually holds.
    ///      Hint: _subscribe(alice, 1_000e6), then compare tBill.balanceOf(alice) with
    ///      custodian.realHoldings(). One of them is 1000e18; the other is zero. Assert both,
    ///      then ask yourself which contract ever talked to the custodian.
    function test_Ex2_SharesExistWhileTheCustodianHoldsNothing() public {
        _subscribe(alice, 1_000e6);

        // 1000USDC平价换1000份
        assertEq(tBill.balanceOf(alice), 1_000e18, "alice holds 1000 shares at par");
        assertEq(vault.totalClaimValue(), 1_000e6, "the book says the fund is worth 1000 USDC");

        // 账上为0，钱在vault
        assertEq(custodian.realHoldings(), 0, "the custodian holds nothing");
        assertEq(vault.reserveBalance(), 1_000e6, "the cash never left the vault");
        assertEq(usdc.balanceOf(address(custodian)), 0, "no USDC reached the custodian");
    }

    /// @dev The custodian's `treasury` is a number a permissioned address can move. Prove that
    ///      the "backing" is a typed-in integer, not cash that arrived.
    ///      Hint: recordPurchase is onlyRole(CUSTODIAN_ROLE) and `admin` holds it. Call
    ///      custodian.recordPurchase(1_000_000e6), then assert realHoldings() jumped while
    ///      usdc.balanceOf(address(custodian)) is still zero.
    function test_Ex2_RealHoldingsIsJustANumber() public {
        assertEq(custodian.realHoldings(), 0, "nothing on the books yet");
        assertEq(usdc.balanceOf(address(custodian)), 0, "and no cash either");

        custodian.recordPurchase(1_000_000e6);

        assertEq(custodian.realHoldings(), 1_000_000e6, "the treasury is now 1,000,000 USDC");
        assertEq(usdc.balanceOf(address(custodian)), 0, "no USDC arrived at the custodian");
        assertEq(usdc.totalSupply(), 0, "no USDC exists anywhere in this test");

        // 先读角色防止prank被view调用用掉
        bytes32 role = custodian.CUSTODIAN_ROLE();
        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, attacker, role
            )
        );
        custodian.recordPurchase(1);
    }

    // ==================================================================
    // Ex3 · plank (b) attestation — the chain's only window is one number
    // ==================================================================

    /// @dev Subscribe at par, then have the reporter move the NAV up. Assert the two things
    ///      that make this an RWA and not a stablecoin: the share COUNT is unchanged, and the
    ///      VALUE of the position moved. A stablecoin would have kept things 1:1.
    ///      Hint: _subscribe(alice, 1_000e6); read tBill.balanceOf(alice) and
    ///      vault.totalClaimValue(); then vault.attest(int256(NAV_1_25)); read both again.
    ///      Shares stay 1000e18; the claim goes 1000e6 -> 1250e6.
    function test_Ex3_TheClaimFloats_TheShareCountDoesNot() public {
        _subscribe(alice, 1_000e6);

        uint256 sharesBefore = tBill.balanceOf(alice);
        uint256 claimBefore = vault.totalClaimValue();
        assertEq(sharesBefore, 1_000e18, "1000 USDC at par = 1000 shares");
        assertEq(claimBefore, 1_000e6, "at par the claim equals what was paid");

        vault.attest(int256(NAV_1_25));

        // 份数1000但价值变为1250，并非稳定币
        assertEq(tBill.balanceOf(alice), sharesBefore, "the share count is unchanged");
        assertEq(tBill.totalSupply(), sharesBefore, "no shares were minted or burned");
        assertEq(vault.totalClaimValue(), 1_250e6, "the whole book is now worth 1250 USDC");
        assertEq(
            vault.assetsForShares(tBill.balanceOf(alice)),
            1_250e6,
            "alice's unchanged balance is now a claim on 1250 USDC"
        );
        assertEq(vault.totalClaimValue() - claimBefore, 250e6, "250 USDC of value appeared");

        // 多出的250并非vault的现金
        assertEq(vault.reserveBalance(), 1_000e6, "the buffer still holds exactly 1000 USDC");
    }

    /// @dev One number re-prices the entire book. Two holders, one call, and both claim values
    ///      move together. attest is gated by REPORTER_ROLE — `admin` holds it — but nothing
    ///      downstream can question the number it writes.
    ///      Hint: _subscribe alice and bob, then vault.attest. A single holder's claim value is
    ///      vault.assetsForShares(tBill.balanceOf(who)). Pick a moderate NAV (e.g. 50e8) so the
    ///      totals stay small and readable.
    function test_Ex3_OneCallMovesTheWholeBook() public {
        _subscribe(alice, 1_000e6);
        _subscribe(bob, 2_000e6);

        uint256 aliceShares = tBill.balanceOf(alice);
        uint256 bobShares = tBill.balanceOf(bob);
        assertEq(aliceShares, 1_000e18);
        assertEq(bobShares, 2_000e18);
        assertEq(vault.assetsForShares(aliceShares), 1_000e6, "alice's claim at par");
        assertEq(vault.assetsForShares(bobShares), 2_000e6, "bob's claim at par");
        assertEq(vault.totalClaimValue(), 3_000e6, "the book at par");

        // 两人一起被重新定价
        vault.attest(int256(50e8));

        assertEq(tBill.balanceOf(alice), aliceShares, "alice's count did not move");
        assertEq(tBill.balanceOf(bob), bobShares, "bob's count did not move");
        assertEq(vault.assetsForShares(aliceShares), 50_000e6, "alice: 1000 shares x 50");
        assertEq(vault.assetsForShares(bobShares), 100_000e6, "bob: 2000 shares x 50");
        assertEq(vault.totalClaimValue(), 150_000e6, "the whole book moved 50x");

        // 托管方和现金没变，新价格无法反驳
        assertEq(custodian.realHoldings(), 0, "the custodian did not change");
        assertEq(vault.reserveBalance(), 3_000e6, "the cash did not change");
        assertGt(vault.totalClaimValue(), vault.reserveBalance() + custodian.realHoldings());
    }

    // ==================================================================
    // Ex4 · plank (d) admission — where the guard is, and who holds the key
    // ==================================================================

    /// @dev An address that never passed KYC cannot receive shares, even by paying for them.
    ///      Hint: faucet the attacker and approve the vault FIRST, or you revert for the wrong
    ///      reason. Then vm.expectRevert + abi.encodeWithSelector to pin down
    ///      TBillToken.NotWhitelisted(attacker). A vague "it reverted" stays green even after
    ///      the guard is removed, so assert the exact selector.
    function test_Ex4_NoKyc_NoShares_EvenIfYouPay() public {
        assertFalse(compliance.isWhitelisted(attacker), "the attacker never passed KYC");

        // 先打钱、授权，只能由于白名单问题失败
        usdc.faucet(attacker, 1_000e6);
        vm.startPrank(attacker);
        usdc.approve(address(vault), 1_000e6);

        vm.expectRevert(abi.encodeWithSelector(TBillToken.NotWhitelisted.selector, attacker));
        vault.subscribe(1_000e6);
        vm.stopPrank();

        assertEq(tBill.balanceOf(attacker), 0, "no shares for the unlisted");
        assertEq(usdc.balanceOf(attacker), 1_000e6, "and the payment was rolled back");
        assertEq(tBill.totalSupply(), 0, "nothing was minted at all");
    }

    /// @dev A whitelisted holder still cannot SEND shares to a non-whitelisted address —
    ///      _update checks both endpoints, not just the sender.
    ///      Hint: alice subscribes, then alice calls tBill.transfer(attacker, 1e18). Pin the
    ///      revert on NotWhitelisted(attacker) — note WHICH address appears in the error.
    function test_Ex4_TransferChecksBothEndpoints() public {
        _subscribe(alice, 1_000e6);
        assertTrue(compliance.isWhitelisted(alice), "the sender is on the list");
        assertFalse(compliance.isWhitelisted(attacker), "the receiver is not");

        // 收款人不在白名单上无法转账
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(TBillToken.NotWhitelisted.selector, attacker));
        tBill.transfer(attacker, 1e18);

        assertEq(tBill.balanceOf(alice), 1_000e18, "alice keeps every share");
        assertEq(tBill.balanceOf(attacker), 0, "the attacker received nothing");

        // 转给白名单上的成员，验证结论
        vm.prank(alice);
        tBill.transfer(bob, 1e18);
        assertEq(tBill.balanceOf(bob), 1e18, "a listed receiver is fine");
    }

    /// @dev Removing an address from the list freezes that individual holder — and it is
    ///      stronger than it looks. The same _update guard sits in front of burn(), so once
    ///      alice is off the list the issuer cannot confiscate her shares either.
    ///      Hint: alice subscribes; compliance.setWhitelisted(alice, false); assert alice's
    ///      transfer reverts; then assert tBill.burn(alice, 1_000e18) called by admin ALSO
    ///      reverts NotWhitelisted(alice). Do not reach for pause() — that is a global switch,
    ///      a different question (STUDENT-QUESTIONS.md C2).
    function test_Ex4_FreezeBeatsConfiscation() public {
        _subscribe(alice, 1_000e6);
        assertEq(tBill.balanceOf(alice), 1_000e18);

        // 移除，余额仍在但无法操控
        compliance.setWhitelisted(alice, false);
        assertEq(tBill.balanceOf(alice), 1_000e18, "de-listing does not touch the balance");

        // 发送方报错
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(TBillToken.NotWhitelisted.selector, alice));
        tBill.transfer(bob, 1e18);

        // 发行方无法烧掉
        assertTrue(tBill.hasRole(tBill.MINTER_ROLE(), admin), "admin can burn in principle");
        vm.expectRevert(abi.encodeWithSelector(TBillToken.NotWhitelisted.selector, alice));
        tBill.burn(alice, 1_000e18);

        // 全部冻结
        assertEq(tBill.balanceOf(alice), 1_000e18, "the shares are frozen, not gone");
        assertEq(tBill.totalSupply(), 1_000e18, "nothing was burned");

        // 加回名单才可没收
        compliance.setWhitelisted(alice, true);
        tBill.burn(alice, 1_000e18);
        assertEq(tBill.balanceOf(alice), 0, "re-listed, the burn goes through");
    }
}
