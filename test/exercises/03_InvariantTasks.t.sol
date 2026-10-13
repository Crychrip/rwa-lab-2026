// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";

import {MockUSDC} from "../../src/MockUSDC.sol";
import {ComplianceRegistry} from "../../src/ComplianceRegistry.sol";
import {TBillToken} from "../../src/TBillToken.sol";
import {TBillVault} from "../../src/TBillVault.sol";
import {MockPriceFeed} from "../../src/exercises/MockPriceFeed.sol";
import {MockTBillCustodian} from "../../src/exercises/MockTBillCustodian.sol";
import {RedemptionQueue} from "../../src/exercises/RedemptionQueue.sol";

/// @title Ex6 — the two bridge invariants
/// @notice Invariant testing flips the usual test around: let the machine call operations
///         randomly and repeatedly, then ask "no matter how it thrashes, does this property
///         still hold?" That is how a bridge should be tested — you will never guess the order
///         an attacker does things in.
///
///         Acceptance: make exercise (it should be red until you are finished)
///
/// @dev Ex6 depends on Ex5: the handler below calls enqueue / settle / claim, which are the
///      four functions you implement in RedemptionQueue.sol. Finish Ex5 first, or the fuzzer
///      will only ever see reverts.
///
///      How it works: Foundry picks a function from the handler at random, picks random
///      arguments, calls it, and repeats N times; after each round it runs every invariant_*
///      function. The first failed assertion is a counterexample.
contract BridgeHandler is Test {
    MockUSDC internal usdc;
    TBillToken internal tBill;
    TBillVault internal vault;
    RedemptionQueue internal queue;

    address[3] public users;

    /// @dev Bookkeeping: proves the fuzzer really reached the handler instead of idling
    uint256 public ghost_enqueues;
    uint256 public ghost_settles;
    uint256 public ghost_claims;

    constructor(MockUSDC usdc_, TBillToken tBill_, TBillVault vault_, RedemptionQueue queue_) {
        usdc = usdc_;
        tBill = tBill_;
        vault = vault_;
        queue = queue_;

        users[0] = makeAddr("user0");
        users[1] = makeAddr("user1");
        users[2] = makeAddr("user2");
        for (uint256 i; i < users.length; ++i) {
            usdc.faucet(users[i], 100_000e6);
        }
    }

    /// @dev Given — pay USDC, receive shares at today's NAV
    function subscribe(uint256 userSeed, uint256 amount) external {
        address user = users[bound(userSeed, 0, users.length - 1)];

        uint256 balance = usdc.balanceOf(user);
        if (balance == 0) return;
        amount = bound(amount, 1, balance);

        vm.startPrank(user);
        usdc.approve(address(vault), amount);
        vault.subscribe(amount);
        vm.stopPrank();
    }

    /// @dev Given — the reporter moves the NAV. Kept inside a sane band so the fuzzer spends
    ///      its budget on the queue rather than on absurd prices.
    function attest(uint256 navSeed) external {
        vault.attest(int256(bound(navSeed, 0.5e8, 2e8)));
    }

    /// @dev Given — the SPV wires cash back into the vault, the way T+1 proceeds would arrive
    function fundVault(uint256 amount) external {
        uint256 balance = usdc.balanceOf(address(this));
        if (balance == 0) return;
        amount = bound(amount, 1, balance);

        usdc.approve(address(vault), amount);
        vault.depositReserves(amount);
    }

    /// TODO Ex6.1 — implement enqueue
    /// @dev Steps:
    ///       1) pick one user at random (a user may hold 0 tBILL — if so, return early)
    ///       2) bound the shares to [1, that user's tBILL balance]
    ///       3) call queue.enqueue(shares) as that user
    ///       4) do not forget the approval — enqueue pulls the shares in with transferFrom
    ///      Hint: the two parameters have no names yet. Name them first.
    function enqueue(uint256 userSeed, uint256 shares) external {
        address user = users[bound(userSeed, 0, users.length - 1)];

        uint256 balance = tBill.balanceOf(user);
        if (balance == 0) return;
        shares = bound(shares, 1, balance);

        vm.startPrank(user);
        tBill.approve(address(queue), shares);
        queue.enqueue(shares);
        vm.stopPrank();

        ghost_enqueues++;
    }

    /// TODO Ex6.2 — implement settle
    /// @dev Steps:
    ///       1) bound `assets` to [1, vault.reserveBalance()] (return early if the vault is empty)
    ///       2) call queue.settle(assets)
    ///      Settling with less cash than the head ticket needs is legal — it simply pays nothing.
    function settle(uint256 assets) external {
        uint256 reserve = vault.reserveBalance();
        if (reserve == 0) return;
        assets = bound(assets, 1, reserve);

        // The handler holds SETTLER_ROLE, so this is called as the handler itself. Whatever
        // settle() pays out is <= assets <= reserve, so releaseReserves cannot run dry here.
        queue.settle(assets);

        ghost_settles++;
    }

    /// TODO Ex6.3 — implement claim
    /// @dev Steps:
    ///       1) pick one user at random
    ///       2) if that user has nothing claimable, return early
    ///       3) call queue.claim() as that user
    function claim(uint256 userSeed) external {
        address user = users[bound(userSeed, 0, users.length - 1)];
        if (queue.claimable(user) == 0) return;

        vm.prank(user);
        queue.claim();

        ghost_claims++;
    }
}

contract InvariantTasksTest is Test {
    MockUSDC internal usdc;
    ComplianceRegistry internal compliance;
    TBillToken internal tBill;
    MockTBillCustodian internal custodian;
    TBillVault internal vault;
    RedemptionQueue internal queue;
    BridgeHandler internal handler;

    address internal admin = address(this);

    function setUp() public {
        usdc = new MockUSDC();
        compliance = new ComplianceRegistry(admin);
        MockPriceFeed feed = new MockPriceFeed(1e8);
        tBill = new TBillToken(admin, compliance);
        custodian = new MockTBillCustodian(admin);
        vault = new TBillVault(usdc, tBill, feed, custodian, admin);
        queue = new RedemptionQueue(vault, tBill, usdc, admin);

        tBill.grantRole(tBill.MINTER_ROLE(), address(vault));
        tBill.grantRole(tBill.MINTER_ROLE(), address(queue));
        custodian.grantRole(custodian.CUSTODIAN_ROLE(), address(vault));
        vault.setQueue(address(queue));

        compliance.setWhitelisted(address(queue), true);

        handler = new BridgeHandler(usdc, tBill, vault, queue);

        for (uint256 i; i < 3; ++i) {
            compliance.setWhitelisted(handler.users(i), true);
        }
        compliance.setWhitelisted(address(handler), true);

        vault.grantRole(vault.REPORTER_ROLE(), address(handler));
        vault.grantRole(vault.OPERATOR_ROLE(), address(handler));
        queue.grantRole(queue.SETTLER_ROLE(), address(handler));

        // Let the fuzzer call only the handler's own actions, not its inherited helpers
        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = BridgeHandler.subscribe.selector;
        selectors[1] = BridgeHandler.attest.selector;
        selectors[2] = BridgeHandler.fundVault.selector;
        selectors[3] = BridgeHandler.enqueue.selector;
        selectors[4] = BridgeHandler.settle.selector;
        selectors[5] = BridgeHandler.claim.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /// TODO Ex6.4 — escrow conservation (plank c)
    /// @dev The queue holds exactly the shares it still owes a payout for. It never loses one
    ///      and never invents one. The assertion below is wrong on purpose (it asserts a
    ///      constant 1), which is why it goes red. Turn it into the property you want.
    function invariant_EscrowConservation() public view {
        // Every share the queue physically holds is a share it still owes a payout for, and
        // vice versa. enqueue adds to both sides; settle burns and subtracts from both sides.
        // Drop the `pendingShares -= shares` in settle and this is the line that goes red.
        assertEq(
            tBill.balanceOf(address(queue)),
            queue.pendingShares(),
            "escrow conservation: the queue holds exactly the shares it still owes for"
        );
    }

    /// TODO Ex6.5 — settlement solvency (plank c)
    /// @dev The queue never owes settled cash it does not hold: it pays at least what the
    ///      claimable balances add up to. The assertion below is deliberately false.
    ///
    ///      Then ask yourself why nobody can write the more tempting invariant:
    ///        vault.reserveBalance() >= queue.pendingAssets()
    ///      Hint: when the NAV rises, where does the extra value physically sit? Is it in the
    ///      vault's USDC buffer, or in the T-Bills at the custodian? That gap is the whole
    ///      lesson of this lab — write your answer up as question C1.
    function invariant_SettlementSolvency() public view {
        // Cash only enters the queue through settle (exactly a ticket's payout, credited to
        // claimable at the same time) and only leaves through claim (which debits claimable
        // first). So the queue can never owe settled cash it is not actually holding.
        assertGe(
            usdc.balanceOf(address(queue)),
            queue.totalClaimable(),
            "settlement solvency: the queue holds at least what it has promised to pay"
        );
    }

    /// @dev Sanity: did the fuzzer really drive the queue, or did the handler return early
    ///      every time? Deliberately NOT written as an invariant — Foundry checks invariants
    ///      once before the first random call, when every ghost counter is still zero, so an
    ///      assertion here would fail for the wrong reason. The hook just logs the counters
    ///      after each run (visible with -vv) so a silent no-op handler is easy to spot.
    function afterInvariant() public view {
        console.log("enqueues", handler.ghost_enqueues());
        console.log("settles ", handler.ghost_settles());
        console.log("claims  ", handler.ghost_claims());
    }
}
