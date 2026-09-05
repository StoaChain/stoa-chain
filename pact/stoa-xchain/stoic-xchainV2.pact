;;  stoic-xchainV2.pact
;;
;;  V2 of the cross-chain gas-station module. The original module
;;  `stoa-ns.stoic-xchain` (defined in pact/genesis/stoa/stoa-genesis-5.pact) is
;;  LEFT INTACT. This is a NEW module, `stoa-ns.stoic-xchain-v2`, deployed
;;  alongside it.
;;
;;  WHY V2 EXISTS
;;  ------------
;;  V1 built the gas-station price guard like this:
;;      (minimum-stoa-gas-price:decimal (/ (dec (coin.UC_MinimumGasPriceANU)) 1e12))  ; evaluated ONCE
;;      (create-user-guard (util.gas-guards.enforce-below-or-at-gas-price minimum-stoa-gas-price))
;;  `create-user-guard` strictly evaluates and FREEZES its arguments at creation
;;  time, so the price ceiling was baked in as the floor-at-account-creation and
;;  never moved. Once the Yin engine enforces `price >= current-floor` at
;;  consensus and the floor rises above that frozen value (already true today),
;;  the frozen ceiling admits nothing and the gas station can pay for no
;;  cross-chain transaction. See pact/stoa-xchain/proof-user-guard-freezes.repl.
;;
;;  THE FIX
;;  -------
;;  V2's price guard is an ARGUMENT-LESS predicate that reads
;;  coin.UC_MinimumGasPriceSTOA at ENFORCEMENT time, so it tracks the live floor.
;;  `update-xchain-gas-account` rotates an existing account's guard onto it
;;  in place (no account recreation).
;;
;;  DEPLOY / USE
;;  ------------
;;   1. Deploy this module (tx signed with ns-admin-keyset).
;;   2. Rotate the live account(s):
;;        (stoa-ns.stoic-xchain-v2.update-xchain-gas-account "stoa-xchain-gas")
;;      signed with ns-admin-keyset -- it satisfies both GOVERNANCE and the
;;      account's current enforce-or(ns-admin-keyset, ...) branch, which is what
;;      coin.rotate's ROTATE -> UEV_Rotate -> CAP_Account enforces.
;;   3. Fund the account with STOA so it can pay cross-chain gas.
;;  Do steps 1-3 BEFORE the Yin-engine (v3.2.1-stoa.3) fork height, and before
;;  clients switch cross-chain gas payment to <stoa-xchain-gas>.

(namespace "stoa-ns")

(module stoic-xchain-v2 GOVERNANCE
    @doc "V2: dynamic-floor cross-chain gas-station guard + in-place guard upgrade."

    (use coin)
    (use util.guards)
    (use util.gas-guards)

    (defcap GOVERNANCE ()
        @doc "Governed by ns-admin-keyset (same authority as V1)."
        (enforce-guard (keyset-ref-guard "ns-admin-keyset")))

    ;; -- The dynamic price predicate (the fix) --------------------------------
    (defun enforce-at-or-below-current-min-gas-price:bool ()
        @doc "Enforce the transaction's gas price is at or below the CURRENT protocol \
            \ minimum. Takes NO argument: coin.UC_MinimumGasPriceSTOA is read live on \
            \ every enforcement, so the ceiling rises with the floor instead of freezing. \
            \ (chain-gas-price = (at 'gas-price (chain-data)) via util.gas-guards.)"
        (enforce
            (<= (chain-gas-price) (coin.UC_MinimumGasPriceSTOA))
            (format "Gas price {} is above the current protocol minimum {}"
                    [(chain-gas-price) (coin.UC_MinimumGasPriceSTOA)])))

    ;; -- The full gas-station guard (shared by create + update) ---------------
    ;; Structurally identical to V1: admin OR (gas-only AND price AND limit<=850);
    ;; only the price sub-guard is swapped for the dynamic one above.
    (defun UDC_XChainGasGuard:guard ()
        @doc "Build the final gas-station guard: enforce-or(admin, gas-restriction)."
        (create-user-guard
            (util.guards.enforce-or
                (keyset-ref-guard "ns-admin-keyset")
                (create-user-guard
                    (util.gas-guards.enforce-guard-all
                        [ (create-user-guard (coin.gas-only))
                          (create-user-guard (enforce-at-or-below-current-min-gas-price))
                          (create-user-guard (util.gas-guards.enforce-below-or-at-gas-limit 850))
                        ])))))

    ;; -- Fixed creator (retained for correctness/future; NOT used to fix the
    ;;    already-live accounts -- use update-xchain-gas-account for those) -----
    (defun create-xchain-gas-account:string (account-name:string)
        @doc "Create a cross-chain gas account with the V2 dynamic-floor guard."
        (with-capability (GOVERNANCE)
            (coin.C_CreateAccount account-name (UDC_XChainGasGuard))
            (format "Account <{}> created with V2 dynamic-floor guard" [account-name])))

    ;; -- The upgrade: rotate an EXISTING account's guard onto the dynamic one --
    (defun update-xchain-gas-account:string (account-name:string)
        @doc "Rotate an existing gas-station account's guard to the V2 dynamic-floor \
            \ guard, in place. Sign with ns-admin-keyset (satisfies GOVERNANCE and the \
            \ account's current admin branch that coin.rotate's ROTATE cap enforces)."
        (with-capability (GOVERNANCE)
            (coin.C_RotateAccount account-name (UDC_XChainGasGuard))
            (format "Account <{}> guard rotated to V2 dynamic-floor guard" [account-name])))
)
