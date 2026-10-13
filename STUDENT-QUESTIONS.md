# STUDENT-QUESTIONS.md — Discussion questions (goes inside your submission zip)

Answer directly under each question. 150–300 words each — **reasoning over length**.

The sections follow the four planks of the bridge. There are no standard answers; these are the
real point of the lab.

---

## A. Custody — where the asset actually is (plank a)

**A1.** In Lab 1, `totalCollateral()` read the vault's own ERC-20 balance, and the chain could
prove the invariant. Here, `MockTBillCustodian.realHoldings()` is just a number that a permissioned
address can move. Write the equivalent of `totalCollateral() == totalSupply()` for *this* system.
What does it actually assert, and what does it no longer prove?

> Your answer:
>
> The nearest equivalent is a **solvency** statement rather than a **conservation** one:
> `custodian.realHoldings() >= vault.totalClaimValue()` — the T-Bills actually held are worth at
> least the sum of every share's claim at the attested NAV. (Both sides are 6-decimal USDC units.)
>
> What it *asserts* is that the fund is backed: the off-chain assets cover what the book says it
> owes. What it no longer *proves* is anything at all. In Lab 1, `totalCollateral()` read the
> vault's own ERC-20 balance, so the chain could count both sides itself and the equality was
> trustless and self-evident. Here **both** sides of the inequality are numbers a privileged role
> types in: `realHoldings()` is written by `CUSTODIAN_ROLE` via `recordPurchase`, and the NAV
> inside `totalClaimValue()` is written by `REPORTER_ROLE` via `attest`. The chain cannot look
> behind either. So the relation degrades from a *proof the EVM enforces* to a *promise two
> off-chain actors make*. It is exactly the gap Ex2 and Ex7 exploit: the number can say "backed"
> while the box is empty.

<br><br><br>

**A2.** The T-Bills are held by an SPV, a legal entity set up so the fund's assets are bankruptcy-
remote from the issuer. Explain in your own words why a *legal* structure is part of a *technical*
design. If the SPV's custodian goes bankrupt, what does the on-chain token entitle its holder to?

> Your answer:
>
> A *legal* structure is part of a *technical* design because the thing being tokenized is a
> **claim**, and the value of a claim in a default is decided entirely by law, not by code. The EVM
> can transfer a token, but it cannot make a bankruptcy court hand you a Treasury bill. The SPV is
> the mechanism that makes the claim worth something: it is a separate legal entity that owns the
> T-Bills and is *bankruptcy-remote* from the issuer/manager, so if the manager fails, the assets
> are not swept into the manager's estate and token holders are not left as unsecured creditors of
> a failed company. That property cannot be expressed in Solidity, so it has to be bolted on in the
> legal layer — the code simply trusts it exists.
>
> If the SPV's **custodian** goes bankrupt, what the token entitles you to depends on custody law
> and whether the assets were properly *segregated*. If the T-Bills were held in a segregated
> client account, they are not the custodian's property and holders can recover them (via the SPV)
> through a successor custodian. If they were commingled with the custodian's own assets, holders
> drop to unsecured creditors in the custodian's insolvency and may recover cents on the dollar.
> Either way the on-chain balance is only *evidence* of the claim — the claim itself lives in the
> fund documents.

<br><br><br>

---

## B. Attestation — how the chain learns the truth (plank b)

**B1.** `attest()` is the only function that moves the NAV, and it is gated by `REPORTER_ROLE`.
Everything downstream — subscription pricing, redemption payouts, both invariants — believes that
number. Name the failure modes of a single trusted reporter, and one mechanism (technical,
financial, or legal) that mitigates each.

> Your answer:
>
> A single trusted reporter fails in at least four ways:
>
> 1. **Wrong number (error).** A fat-fingered or mis-computed NAV re-prices the whole book
>    instantly (Ex3). *Mitigation (technical):* sanity bounds / deviation caps in `attest` that
>    reject a move larger than, say, a few percent per update, plus a multi-reporter median so no
>    one key sets the value alone.
> 2. **Malicious number (compromise).** A leaked signing key or bribed operator posts a lie and
>    drains the fund — exactly Ex7. *Mitigation (technical):* a timelock between `attest` and the
>    value taking effect for pricing/payouts, so a false mark can be spotted and vetoed before it
>    becomes cash; hardware-backed keys and role separation.
> 3. **Stale / frozen number.** The reporter stops updating and the book drifts from reality (B2).
>    *Mitigation (technical):* a heartbeat / `updatedAt` staleness check that halts
>    subscribe/redeem when the data is too old, with a fallback feed.
> 4. **Honest-but-unaccountable.** The reporter is simply trusted with no recourse.
>    *Mitigation (legal/financial):* use a licensed fund administrator who strikes the NAV under
>    audit, carry errors-and-omissions insurance, and make the attestation a contractual/regulatory
>    obligation so a bad mark has consequences off-chain.

<br><br><br>

**B2.** A production feed would check whether `updatedAt` is stale; this lab's mock does not. A
**frozen** NAV is a different attack from a **wrong** NAV. Describe how a stale-but-honest NAV can
be exploited by someone who knows the true value has moved.

> Your answer:
>
> A **wrong** NAV misprices everyone symmetrically at one instant; a **stale** NAV creates a
> *known, one-sided* gap that an informed actor can harvest repeatedly, risk-free. Because this
> lab's feed returns `block.timestamp` for `updatedAt` and the vault never checks it, the last
> attested answer is used forever, for both `subscribe` and the queue's payout.
>
> Suppose the true NAV has risen (rates fell, the T-Bills accrued) but the feed is frozen at the
> old, lower number. Someone who knows the real value `subscribe`s at the stale **low** price: the
> vault mints them more shares than their cash deserves, because `sharesForAssets` divides by the
> too-small NAV. When the feed finally catches up, their shares are worth more than they paid —
> free value transferred from the honest holders. The mirror case: if the true NAV has *fallen* but
> the feed is still high, an informed holder `enqueue`s to lock the stale **high** payout and
> redeems before the mark drops, exiting at a price the fund can no longer realize by selling the
> actual T-Bills. Either way the attacker trades against a price the chain *knows* is stale but has
> no rule to reject. The fix is a staleness guard: revert when `block.timestamp - updatedAt`
> exceeds a heartbeat.

<br><br><br>

---

## C. Redemption — T+1 does not settle on-chain (plank c)

**C1.** The queue locks the payout at the NAV of **enqueue** time, not **settle** time. If the NAV
rises between the two, who gains and who loses — the redeemer, or the holders who stayed? Is that
the right allocation of risk, and how would you change it?

> Your answer:
>
> `enqueue` calls `assetsAtNav(shares, vault.navPerShare())` and stores the result in
> `assetsLocked`; `settle` pays that stored number regardless of the NAV at settlement time. So the
> redeemer's payout is frozen the moment they join the queue. If the NAV **rises** between enqueue
> and settle, the redeemer **loses** the upside — they still get the lower enqueue-time price — and
> the **holders who stayed gain**, because the value the redeemer left on the table accrues to the
> remaining shares. If the NAV falls, it is reversed: the redeemer is protected at the higher locked
> price and the stayers absorb the drop.
>
> Is that the right allocation? Locking at enqueue is *defensible*: the redeemer has signalled they
> are leaving the fund's risk, so arguably they should stop earning its returns at that instant.
> But it is not *fair to realized value*, because the fund only gets cash by actually selling
> T-Bills at settlement — the redeemer bears a day of settlement/ T+1 risk with none of its reward,
> and in a rising market they systematically subsidize the stayers. I would price the payout at
> **settle-time NAV** (ideally the *actual execution price* the SPV achieves selling the bills),
> which matches what the fund truly realized, optionally inside a collar to cap the redeemer's
> day-of volatility. That removes the free transfer either direction and ties the payout to reality
> rather than to a number locked a day early.

<br><br><br>

**C2.** In a 2008 money-market fund breaking the buck, and in USDC's 2023 depeg, redemptions were
handled very differently. Compare the two. For a tokenized T-Bill fund, what does it mean to "close
the redemption channel", and what should happen to the queue when it does? Then look at the lever
this lab actually ships: `pause()` (`PAUSER_ROLE`) freezes transfers, minting **and** redemption
together — one switch, no partial setting. Why is that the wrong tool for a liquidity squeeze, and
what would you rather have?

> Your answer:
>
> **2008 (Reserve Primary Fund)** vs **2023 (USDC depeg)** differ in whether the exit stayed open.
> In 2008 the fund "broke the buck" (NAV below \$1), redemptions were **frozen** for days, and the
> panic fed on itself — a *liquidity* failure turned into a run because nobody could get out. In
> 2023 USDC fell to \$0.87 on the SVB scare but the **redemption channel stayed open**; arbitrageurs
> could keep redeeming 1:1 at Circle, so the price snapped back within days. The open door was what
> contained it.
>
> For a tokenized T-Bill fund, "closing the redemption channel" means the queue stops honouring
> tickets — `settle`/`claim` no longer pay. What *should* happen to the queue when it closes: the
> existing tickets must **keep their FIFO place and their escrowed shares**, and settle fairly (in
> order, or pro-rata if cash is short) once the T+1 proceeds arrive — tickets are paused, never
> cancelled.
>
> The lever this lab ships, `pause()`, is the wrong tool for a liquidity squeeze because it is a
> single global kill switch: it freezes transfers, minting **and** redemption together, with no
> partial setting. A liquidity problem is "not enough cash *right now*", not "the whole system is
> unsafe" — but `pause()` also halts healthy secondary-market transfers and new subscriptions,
> which amplifies the panic exactly as 2008 did. I would rather have a **redemption-specific gate**:
> a throttle that lets the queue settle pro-rata or with per-epoch caps / notice periods while
> transfers stay live — a dimmer switch, not a breaker.

<br><br><br>

---

## D. Admission — the guest list and the backdoor (plank d)

**D1.** Every balance change in `TBillToken._update` checks **both** endpoints against the
whitelist. That is what stops a sanctioned address from receiving shares — and also what stops a
completely ordinary user who has not finished KYC. Where is the right line for a regulated fund,
and who should be able to move it?

> Your answer:
>
> `_update` checks **both** endpoints against the whitelist, so the same line that blocks a
> sanctioned address also blocks an ordinary person who simply has not finished KYC. For a regulated
> security that two-sided check is not optional: the transfer agent is legally required to know who
> holds the security, so permissioning is the price of being a compliant fund rather than a bearer
> token. The right line, then, is not "permissionless vs permissioned" — it has to be permissioned —
> but *how the list is administered*: onboarding must be clear, documented, and auditable; removals
> must be for a stated, lawful reason (sanctions, fraud, expired KYC), logged, and reviewable; and
> the gate must not be usable to arbitrarily or discriminatorily exclude an otherwise-eligible
> holder.
>
> Who should move it: a **regulated compliance / transfer-agent function** operating under KYC/AML
> rules and subject to audit — not the fund *manager* acting unilaterally, because the manager has a
> financial interest and the whitelist is a censorship power. Ideally the `COMPLIANCE_ROLE` sits
> behind a multi-sig held by the compliance officer plus an independent party, with every change
> emitting an on-chain event for oversight. The tradeoff is real: a tighter list is more compliant
> but more centralized and censorable; a looser one is more open but risks sanctions violations. The
> balance is strict *criteria* with transparent, accountable *administration*.

<br><br><br>

**D2.** A regulated fund asks for two levers: freeze an address (`setWhitelisted(addr, false)`) and
burn a balance (`MINTER_ROLE`) — both censorship tools, both justified by the product. But Ex4.3
shows the two **collide**: once an address is off the list, `burn()` reverts as well, because
`_update` guards both endpoints. So a freeze also blocks a seizure. Argue **both** sides of handing
an issuer these powers, then say what safeguards you would add and who should hold each key.

> Your answer:
>
> **For handing the issuer these powers.** A regulated fund genuinely needs them. A court can order
> a sanctioned or fraudulent holder's position frozen or seized; a holder may lose their keys and
> need their balance reissued; AML law can require blocking a tainted address. Without `freeze`
> (`setWhitelisted(addr, false)`) and `burn` (`MINTER_ROLE`), the issuer cannot meet those legal
> duties and the product is not sellable to institutions. These are features, not bugs, for a
> *security* token.
>
> **Against.** They are, plainly, censorship and confiscation powers. A compromised or malicious
> issuer can freeze any holder and burn any balance at will — the token holder's property is
> contingent on the issuer's good behaviour. Ex4.3 even shows the two powers *collide*: once an
> address is de-listed, `burn` reverts too (the `_update` guard fires on `from`), so a freeze
> accidentally blocks the very seizure it might be meant to enable — a sign these blunt levers are
> not designed for nuance.
>
> **Safeguards.** Split the keys and slow them down. `COMPLIANCE_ROLE` (freeze) should sit with an
> independent compliance officer under a multi-sig; `MINTER_ROLE` (burn/seize) should sit behind a
> *separate* multi-sig **plus a timelock**, and fire only on a documented legal order with an
> on-chain event and an appeal window. Never let one key hold both. Add rate limits / caps, an
> independent auditor or board as a co-signer on seizures, and public logging so every use is
> accountable after the fact.

<br><br><br>

---

## E. Tests (Tier 1 required — this is Ex2, Ex3 and Ex4)

Turn the red tests green in `test/exercises/01_BridgeTasks.t.sol` to cover the scenarios below, and
write your test function names here:

| Plank | Scenario | Your test function name |
|---|---|---|
| a | Shares exist while the custodian holds nothing | `test_Ex2_SharesExistWhileTheCustodianHoldsNothing` |
| a | `realHoldings()` moves with no cash moving | `test_Ex2_RealHoldingsIsJustANumber` |
| b | The claim value floats while the share count stays | `test_Ex3_TheClaimFloats_TheShareCountDoesNot` |
| b | One `attest` re-prices every holder at once | `test_Ex3_OneCallMovesTheWholeBook` |
| d | A non-whitelisted address cannot receive shares, even by paying | `test_Ex4_NoKyc_NoShares_EvenIfYouPay` |
| d | A whitelisted holder cannot send shares to a non-whitelisted address | `test_Ex4_TransferChecksBothEndpoints` |
| d | Removing an address freezes that holder — and blocks a burn | `test_Ex4_FreezeBeatsConfiscation` |

Then write one more scenario you consider **most likely to be exploited** on a tokenized fund, and
say which plank it breaks:

> Your answer:
>
> **A compromised or dishonest reporter re-marks the NAV and drains the fund through redemption —
> the false-NAV attack of Ex7. This breaks plank (b), attestation.**
>
> I pick it because it needs *no smart-contract bug at all*: the code works exactly as written, and
> the only requirement is control of one key the system is designed to trust. Across real DeFi, the
> largest losses have come not from clever reentrancy but from **oracle/admin-key compromise** —
> leaked signers, phished operators, insider access. Plank (b) is the single point where the whole
> book takes an off-chain number on faith, and the same number drives *both* the subscribe price and
> the redemption payout, so moving it once is enough to buy cheap and redeem rich. The attack path
> is short (subscribe → attest → enqueue → settle → claim) and leaves the fund underwater while the
> attacker walks away with real USDC, exactly as `test_falseNav` demonstrates. The custodian
> (plank a) can hold the real bills perfectly and it does not help: the lie is on the *valuation*,
> not the *assets*. That is why the mitigations are a timelock on `attest`, multi-reporter medians,
> deviation caps, and a staleness guard — defence has to live on the number itself, because nothing
> downstream questions it.
