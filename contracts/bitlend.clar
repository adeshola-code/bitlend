;; title: Bitlend
;; Summary:
;; A decentralized lending protocol built natively for Bitcoin on Stacks Layer 2,
;; enabling permissionless lending and borrowing of Bitcoin and other supported assets
;; with dynamic interest rates and liquidation mechanisms.
;;
;; Description:
;; This protocol implements a comprehensive lending platform that allows users to:
;; - Supply assets to earn interest
;; - Borrow assets using over-collateralization
;; - Manage loans with flexible repayment options
;; - Participate in liquidations for undercollateralized positions
;;
;; The protocol features:
;; - Multi-asset support with oracle price feeds
;; - Risk management through collateral ratios
;; - Liquidation mechanisms for protocol safety
;; - Protocol-owned fee accumulation
;; - Emergency pause functionality
;;
;; Security Features:
;; - Minimum collateral ratio of 125%
;; - Liquidation threshold at 110%
;; - 10% liquidation penalty
;; - 0.5% protocol fee on borrowing

;; Constants and Definitions
(define-constant ERR_UNAUTHORIZED (err u1000))
(define-constant ERR_INVALID_AMOUNT (err u1001))
(define-constant ERR_INSUFFICIENT_COLLATERAL (err u1002))
(define-constant ERR_LOAN_NOT_FOUND (err u1003))
(define-constant ERR_LOAN_ALREADY_ACTIVE (err u1004))
(define-constant ERR_LOAN_NOT_ACTIVE (err u1005))
(define-constant ERR_BELOW_MIN_COLLATERAL_RATIO (err u1006))
(define-constant ERR_LOAN_NOT_LIQUIDATABLE (err u1007))
(define-constant ERR_PROTOCOL_PAUSED (err u1008))
(define-constant ERR_ASSET_NOT_SUPPORTED (err u1009))
(define-constant ERR_INSUFFICIENT_LIQUIDITY (err u1010))

;; 80% collateral requirement - 125% minimum collateral ratio
(define-constant MIN_COLLATERAL_RATIO u125) ;; percentage * 100
(define-constant LIQUIDATION_THRESHOLD u110) ;; percentage * 100
(define-constant LIQUIDATION_PENALTY u10) ;; 10% penalty
(define-constant PROTOCOL_FEE u5) ;; 0.5% fee (percentage * 10)

;; Data Maps
;; Protocol control
(define-map protocol-control 
  { key: (string-ascii 32) }
  { value: (string-utf8 256) })

;; Track supported assets with their price oracle and decimals
(define-map supported-assets 
  { asset-id: (string-ascii 42) } 
  { 
    oracle-contract: principal,
    decimals: uint,
    active: bool,
    total-supplied: uint,
    total-borrowed: uint
  })

;; User balances for supplied assets
(define-map user-supplies
  { user: principal, asset-id: (string-ascii 42) }
  { amount: uint })

;; Track active loans
(define-map loans 
  { loan-id: uint }
  {
    borrower: principal, 
    collateral-asset: (string-ascii 42),
    collateral-amount: uint,
    borrowed-asset: (string-ascii 42),
    borrowed-amount: uint,
    creation-height: uint,
    last-update-height: uint,
    interest-rate: uint,
    active: bool
  })

;; Track loan IDs by borrower
(define-map user-loans
  { user: principal }
  { loan-ids: (list 20 uint) })

;; Protocol state
(define-data-var protocol-paused bool false)
(define-data-var protocol-owner principal tx-sender)
(define-data-var next-loan-id uint u1)
(define-data-var total-protocol-fees uint u0)

;; Read-only functions

;; Fetch protocol info
(define-read-only (get-protocol-info)
  (let 
    ((paused (var-get protocol-paused))
     (owner (var-get protocol-owner))
     (loan-count (- (var-get next-loan-id) u1))
     (fees (var-get total-protocol-fees)))
    {
      paused: paused,
      owner: owner,
      loan-count: loan-count,
      accumulated-fees: fees
    }))

;; Get asset details
(define-read-only (get-asset-info (asset-id (string-ascii 42)))
  (default-to 
    { 
      oracle-contract: 'ST000000000000000000002AMW42H.fake-oracle,
      decimals: u0,
      active: false,
      total-supplied: u0,
      total-borrowed: u0
    }
    (map-get? supported-assets { asset-id: asset-id })))

;; Get asset price from oracle
(define-read-only (get-asset-price (asset-id (string-ascii 42)))
  (let ((asset-info (get-asset-info asset-id)))
    (if (get active asset-info)
      (contract-call? (get oracle-contract asset-info) get-price asset-id)
      (err ERR_ASSET_NOT_SUPPORTED))))

;; Get user's supplied balance
(define-read-only (get-user-supply (user principal) (asset-id (string-ascii 42)))
  (default-to 
    { amount: u0 }
    (map-get? user-supplies { user: user, asset-id: asset-id })))

;; Get user's loans
(define-read-only (get-user-loan-ids (user principal))
  (default-to 
    { loan-ids: (list) }
    (map-get? user-loans { user: user })))

;; Get loan details
(define-read-only (get-loan (loan-id uint))
  (default-to
    {
      borrower: 'ST000000000000000000002AMW42H,
      collateral-asset: "",
      collateral-amount: u0,
      borrowed-asset: "",
      borrowed-amount: u0,
      creation-height: u0,
      last-update-height: u0,
      interest-rate: u0,
      active: false
    }
    (map-get? loans { loan-id: loan-id })))

;; Calculate collateral ratio for a loan
(define-read-only (calculate-collateral-ratio (loan-id uint))
  (let* 
    ((loan (get-loan loan-id))
     (collateral-price-response (get-asset-price (get collateral-asset loan)))
     (borrowed-price-response (get-asset-price (get borrowed-asset loan)))
     (collateral-decimals (get decimals (get-asset-info (get collateral-asset loan))))
     (borrowed-decimals (get decimals (get-asset-info (get borrowed-asset loan)))))
    
    (if (and (is-ok collateral-price-response) (is-ok borrowed-price-response))
      (let*
        ((collateral-price (unwrap-panic collateral-price-response))
         (borrowed-price (unwrap-panic borrowed-price-response))
         (collateral-value-raw (* (get collateral-amount loan) collateral-price))
         (borrowed-value-raw (* (get borrowed-amount loan) borrowed-price))
         ;; Adjust for decimal differences and calculate ratio
         (collateral-value (/ collateral-value-raw (pow u10 collateral-decimals)))
         (borrowed-value (/ borrowed-value-raw (pow u10 borrowed-decimals)))
         (ratio (if (> borrowed-value u0)
                  (* (/ collateral-value borrowed-value) u100)
                  u0)))
        (ok ratio))
      (err ERR_ASSET_NOT_SUPPORTED))))

;; Check if a loan is liquidatable
(define-read-only (is-loan-liquidatable (loan-id uint))
  (let ((ratio-response (calculate-collateral-ratio loan-id)))
    (if (is-ok ratio-response)
      (let ((ratio (unwrap-panic ratio-response)))
        (< ratio LIQUIDATION_THRESHOLD))
      false)))

;; Check if user's address matches expected
(define-read-only (is-authorized (expected principal) (actual principal))
  (or (is-eq expected actual)
      (is-eq expected (var-get protocol-owner))))

;; Calculate amount with accrued interest
(define-read-only (calculate-accrued-amount (principal-amount uint) (interest-rate uint) (blocks-elapsed uint))
  (let*
    ((interest-per-block (/ interest-rate u10000)) ;; Convert basis points to per-block rate
     (interest-factor (+ u10000 (* interest-per-block blocks-elapsed)))
     (accrued-amount (/ (* principal-amount interest-factor) u10000)))
    accrued-amount))

;; Public functions

;; Supply assets to the protocol
(define-public (supply-asset (asset-id (string-ascii 42)) (amount uint))
  (let
    ((asset-info (get-asset-info asset-id))
     (current-supply (get amount (get-user-supply tx-sender asset-id))))
    
    ;; Validation checks
    (asserts! (not (var-get protocol-paused)) ERR_PROTOCOL_PAUSED)
    (asserts! (get active asset-info) ERR_ASSET_NOT_SUPPORTED)
    (asserts! (> amount u0) ERR_INVALID_AMOUNT)
    
    ;; Transfer asset to contract
    (match (contract-call? .token-trait transfer asset-id amount tx-sender (as-contract tx-sender))
      success
        (begin
          ;; Update user's supply balance
          (map-set user-supplies 
            { user: tx-sender, asset-id: asset-id }
            { amount: (+ current-supply amount) })
          
          ;; Update asset totals
          (map-set supported-assets
            { asset-id: asset-id }
            (merge asset-info { total-supplied: (+ (get total-supplied asset-info) amount) }))
          
          (ok true))
      error (err error))))