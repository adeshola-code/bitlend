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
(define-constant ERR_ORACLE_ERROR (err u1011))

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
    oracle-function: (string-ascii 40),
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

;; Reference to price oracle contract
(define-data-var default-oracle-contract principal 'ST1PQHQKV0RJXZFY1DGX8MNSNYVE3VGZJSRTPGZGM.btc-oracle)

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
      oracle-contract: (var-get default-oracle-contract),
      oracle-function: "get-price",
      decimals: u0,
      active: false,
      total-supplied: u0,
      total-borrowed: u0
    }
    (map-get? supported-assets { asset-id: asset-id })))

;; Get asset price from oracle - fixed to use specific oracle contract
(define-read-only (get-asset-price (asset-id (string-ascii 42)))
  (let ((asset-info (get-asset-info asset-id)))
    (if (get active asset-info)
      ;; Use a specific oracle contract rather than dynamic dispatch
      (contract-call? .btc-oracle get-price asset-id)
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
(define-public (supply-asset (asset-id (string-ascii 42)) (amount uint) (token-contract <token-trait>))
  (let
    ((asset-info (get-asset-info asset-id))
     (current-supply (get amount (get-user-supply tx-sender asset-id))))
    
    ;; Validation checks
    (asserts! (not (var-get protocol-paused)) ERR_PROTOCOL_PAUSED)
    (asserts! (get active asset-info) ERR_ASSET_NOT_SUPPORTED)
    (asserts! (> amount u0) ERR_INVALID_AMOUNT)
    
    ;; Transfer asset to contract
    (match (contract-call? token-contract transfer asset-id amount tx-sender (as-contract tx-sender))
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

;; Withdraw supplied assets
(define-public (withdraw-asset (asset-id (string-ascii 42)) (amount uint) (token-contract <token-trait>))
  (let
    ((asset-info (get-asset-info asset-id))
     (current-supply (get amount (get-user-supply tx-sender asset-id))))
    
    ;; Validation checks
    (asserts! (not (var-get protocol-paused)) ERR_PROTOCOL_PAUSED)
    (asserts! (get active asset-info) ERR_ASSET_NOT_SUPPORTED)
    (asserts! (>= current-supply amount) ERR_INVALID_AMOUNT)
    (asserts! (>= (- (get total-supplied asset-info) (get total-borrowed asset-info)) amount) ERR_INSUFFICIENT_LIQUIDITY)
    
    ;; Update user's supply balance
    (map-set user-supplies 
      { user: tx-sender, asset-id: asset-id }
      { amount: (- current-supply amount) })
    
    ;; Update asset totals
    (map-set supported-assets
      { asset-id: asset-id }
      (merge asset-info { total-supplied: (- (get total-supplied asset-info) amount) }))
    
    ;; Transfer asset from contract to user
    (as-contract
      (contract-call? token-contract transfer asset-id amount tx-sender tx-sender))))

;; Create a new loan
(define-public (create-loan 
  (collateral-asset (string-ascii 42))
  (collateral-amount uint)
  (borrowed-asset (string-ascii 42))
  (borrow-amount uint)
  (collateral-token <token-trait>)
  (borrowed-token <token-trait>))
  
  (let
    ((collateral-info (get-asset-info collateral-asset))
     (borrowed-info (get-asset-info borrowed-asset))
     (loan-id (var-get next-loan-id))
     (block-height block-height)
     ;; Interest rate could be dynamic based on utilization, fixed at 5% APY (500 basis points) for simplicity
     (interest-rate u500))
    
    ;; Validation checks
    (asserts! (not (var-get protocol-paused)) ERR_PROTOCOL_PAUSED)
    (asserts! (get active collateral-info) ERR_ASSET_NOT_SUPPORTED)
    (asserts! (get active borrowed-info) ERR_ASSET_NOT_SUPPORTED)
    (asserts! (> collateral-amount u0) ERR_INVALID_AMOUNT)
    (asserts! (> borrow-amount u0) ERR_INVALID_AMOUNT)
    (asserts! (>= (- (get total-supplied borrowed-info) (get total-borrowed borrowed-info)) borrow-amount) ERR_INSUFFICIENT_LIQUIDITY)
    
    ;; Transfer collateral to contract
    (match (contract-call? collateral-token transfer collateral-asset collateral-amount tx-sender (as-contract tx-sender))
      success
        (begin
          ;; Create the loan
          (map-set loans
            { loan-id: loan-id }
            {
              borrower: tx-sender, 
              collateral-asset: collateral-asset,
              collateral-amount: collateral-amount,
              borrowed-asset: borrowed-asset,
              borrowed-amount: borrow-amount,
              creation-height: block-height,
              last-update-height: block-height,
              interest-rate: interest-rate,
              active: true
            })
          
          ;; Update user's loan IDs
          (let ((user-loan-list (get loan-ids (default-to { loan-ids: (list) } (map-get? user-loans { user: tx-sender })))))
            (map-set user-loans
              { user: tx-sender }
              { loan-ids: (append user-loan-list loan-id) }))
          
          ;; Update asset totals
          (map-set supported-assets
            { asset-id: borrowed-asset }
            (merge borrowed-info { total-borrowed: (+ (get total-borrowed borrowed-info) borrow-amount) }))
          
          ;; Increment loan ID counter
          (var-set next-loan-id (+ loan-id u1))
          
          ;; Calculate collateral ratio to ensure it's above minimum required
          (let ((ratio-response (calculate-collateral-ratio loan-id)))
            (if (is-ok ratio-response)
              (let ((ratio (unwrap-panic ratio-response)))
                (if (>= ratio MIN_COLLATERAL_RATIO)
                  ;; Transfer borrowed asset to user
                  (as-contract
                    (contract-call? borrowed-token transfer borrowed-asset borrow-amount tx-sender tx-sender))
                  (begin
                    ;; Revert loan creation if collateral ratio is too low
                    (map-delete loans { loan-id: loan-id })
                    ;; Return collateral to user
                    (as-contract
                      (contract-call? collateral-token transfer collateral-asset collateral-amount tx-sender tx-sender))
                    ERR_BELOW_MIN_COLLATERAL_RATIO)))
              ERR_ASSET_NOT_SUPPORTED)))
      error (err error))))

;; Repay loan (partial or full)
(define-public (repay-loan (loan-id uint) (repay-amount uint) (borrowed-token <token-trait>))
  (let*
    ((loan (get-loan loan-id))
     (borrowed-info (get-asset-info (get borrowed-asset loan)))
     (current-height block-height)
     (blocks-elapsed (- current-height (get last-update-height loan)))
     (accrued-amount (calculate-accrued-amount (get borrowed-amount loan) (get interest-rate loan) blocks-elapsed))
     (actual-repay-amount (if (> repay-amount accrued-amount) accrued-amount repay-amount))
     (fee-amount (/ (* actual-repay-amount PROTOCOL_FEE) u1000)))
    
    ;; Validation checks
    (asserts! (not (var-get protocol-paused)) ERR_PROTOCOL_PAUSED)
    (asserts! (get active loan) ERR_LOAN_NOT_FOUND)
    (asserts! (> repay-amount u0) ERR_INVALID_AMOUNT)
    
    ;; Transfer repayment amount to contract
    (match (contract-call? borrowed-token transfer 
                          (get borrowed-asset loan) 
                          actual-repay-amount 
                          tx-sender 
                          (as-contract tx-sender))
      success
        (begin
          ;; Update loan details
          (let
            ((remaining-borrowed (- accrued-amount actual-repay-amount)))
            
            ;; Update protocol fee accounting
            (var-set total-protocol-fees (+ (var-get total-protocol-fees) fee-amount))
            
            ;; If fully repaid, close the loan and return collateral
            (if (<= remaining-borrowed u0)
              (begin
                ;; Update loan status
                (map-set loans
                  { loan-id: loan-id }
                  (merge loan { 
                    borrowed-amount: u0,
                    last-update-height: current-height,
                    active: false
                  }))
                
                ;; Update asset totals
                (map-set supported-assets
                  { asset-id: (get borrowed-asset loan) }
                  (merge borrowed-info { 
                    total-borrowed: (- (get total-borrowed borrowed-info) (get borrowed-amount loan)) 
                  }))
                
                ;; Return collateral to borrower
                (as-contract
                  (contract-call? borrowed-token transfer 
                                (get collateral-asset loan) 
                                (get collateral-amount loan) 
                                (as-contract tx-sender) 
                                (get borrower loan))))
              
              ;; Partial repayment - update loan amount
              (begin
                (map-set loans
                  { loan-id: loan-id }
                  (merge loan { 
                    borrowed-amount: remaining-borrowed,
                    last-update-height: current-height
                  }))
                
                ;; Update asset totals for partial repayment
                (map-set supported-assets
                  { asset-id: (get borrowed-asset loan) }
                  (merge borrowed-info { 
                    total-borrowed: (+ (- (get total-borrowed borrowed-info) (get borrowed-amount loan)) remaining-borrowed) 
                  }))))
            
            (ok true)))
      error (err error))))

;; Add collateral to existing loan
(define-public (add-collateral (loan-id uint) (additional-amount uint) (collateral-token <token-trait>))
  (let
    ((loan (get-loan loan-id)))
    
    ;; Validation checks
    (asserts! (not (var-get protocol-paused)) ERR_PROTOCOL_PAUSED)
    (asserts! (get active loan) ERR_LOAN_NOT_FOUND)
    (asserts! (is-eq (get borrower loan) tx-sender) ERR_UNAUTHORIZED)
    (asserts! (> additional-amount u0) ERR_INVALID_AMOUNT)
    
    ;; Transfer additional collateral to contract
    (match (contract-call? collateral-token transfer 
                          (get collateral-asset loan) 
                          additional-amount 
                          tx-sender 
                          (as-contract tx-sender))
      success
        (begin
          ;; Update loan with new collateral amount
          (map-set loans
            { loan-id: loan-id }
            (merge loan { 
              collateral-amount: (+ (get collateral-amount loan) additional-amount)
            }))
          
          (ok true))
      error (err error))))

;; Liquidate an undercollateralized loan
(define-public (liquidate-loan (loan-id uint) (borrowed-token <token-trait>) (collateral-token <token-trait>))
  (let*
    ((loan (get-loan loan-id))
     (liquidatable (is-loan-liquidatable loan-id))
     (collateral-asset-info (get-asset-info (get collateral-asset loan)))
     (borrowed-asset-info (get-asset-info (get borrowed-asset loan)))
     (current-height block-height)
     (blocks-elapsed (- current-height (get last-update-height loan)))
     (accrued-amount (calculate-accrued-amount (get borrowed-amount loan) (get interest-rate loan) blocks-elapsed))
     ;; Calculate liquidation bonus - liquidator gets collateral at a discount
     (penalty-amount (/ (* accrued-amount LIQUIDATION_PENALTY) u100))
     (total-repay-amount (+ accrued-amount penalty-amount))
     (fee-amount (/ (* accrued-amount PROTOCOL_FEE) u1000)))
    
    ;; Validation checks
    (asserts! (not (var-get protocol-paused)) ERR_PROTOCOL_PAUSED)
    (asserts! (get active loan) ERR_LOAN_NOT_FOUND)
    (asserts! liquidatable ERR_LOAN_NOT_LIQUIDATABLE)
    
    ;; Transfer repayment amount from liquidator
    (match (contract-call? borrowed-token transfer 
                          (get borrowed-asset loan) 
                          total-repay-amount
                          tx-sender 
                          (as-contract tx-sender))
      success
        (begin
          ;; Update protocol fee accounting
          (var-set total-protocol-fees (+ (var-get total-protocol-fees) fee-amount))
          
          ;; Update loan status to inactive
          (map-set loans
            { loan-id: loan-id }
            (merge loan { 
              borrowed-amount: u0,
              last-update-height: current-height,
              active: false
            }))
          
          ;; Update asset totals
          (map-set supported-assets
            { asset-id: (get borrowed-asset loan) }
            (merge borrowed-asset-info { 
              total-borrowed: (- (get total-borrowed borrowed-asset-info) (get borrowed-amount loan)) 
            }))
          
          ;; Transfer collateral to liquidator
          (as-contract
            (contract-call? collateral-token transfer 
                          (get collateral-asset loan) 
                          (get collateral-amount loan) 
                          (as-contract tx-sender) 
                          tx-sender))
          
          (ok true))
      error (err error))))

;; Admin functions

;; Add supported asset
(define-public (add-supported-asset (asset-id (string-ascii 42)) (oracle-contract principal) (oracle-function (string-ascii 40)) (decimals uint))
  (begin
    (asserts! (is-eq tx-sender (var-get protocol-owner)) ERR_UNAUTHORIZED)
    
    (map-set supported-assets
      { asset-id: asset-id }
      {
        oracle-contract: oracle-contract,
        oracle-function: oracle-function,
        decimals: decimals,
        active: true,
        total-supplied: u0,
        total-borrowed: u0
      })
    
    (ok true)))

;; Update asset status (active/inactive)
(define-public (set-asset-active (asset-id (string-ascii 42)) (active bool))
  (let ((asset-info (get-asset-info asset-id)))
    (begin
      (asserts! (is-eq tx-sender (var-get protocol-owner)) ERR_UNAUTHORIZED)
      
      (map-set supported-assets
        { asset-id: asset-id }
        (merge asset-info { active: active }))
      
      (ok true))))

;; Update protocol owner
(define-public (set-protocol-owner (new-owner principal))
  (begin
    (asserts! (is-eq tx-sender (var-get protocol-owner)) ERR_UNAUTHORIZED)
    (var-set protocol-owner new-owner)
    (ok true)))

;; Pause/unpause protocol
(define-public (set-protocol-paused (paused bool))
  (begin
    (asserts! (is-eq tx-sender (var-get protocol-owner)) ERR_UNAUTHORIZED)
    (var-set protocol-paused paused)
    (ok true)))

;; Set default oracle contract
(define-public (set-default-oracle (oracle-contract principal))
  (begin
    (asserts! (is-eq tx-sender (var-get protocol-owner)) ERR_UNAUTHORIZED)
    (var-set default-oracle-contract oracle-contract)
    (ok true)))

;; Withdraw protocol fees
(define-public (withdraw-protocol-fees (asset-id (string-ascii 42)) (amount uint) (token-contract <token-trait>))
  (begin
    (asserts! (is-eq tx-sender (var-get protocol-owner)) ERR_UNAUTHORIZED)
    (asserts! (<= amount (var-get total-protocol-fees)) ERR_INVALID_AMOUNT)
    
    (var-set total-protocol-fees (- (var-get total-protocol-fees) amount))
    
    (as-contract
      (contract-call? token-contract transfer 
                    asset-id
                    amount
                    (as-contract tx-sender)
                    (var-get protocol-owner)))
  ))

;; Token trait interface
(define-trait token-trait
  (
    (transfer (string-ascii 42) uint principal principal (response bool uint))
  ))

;; Oracle trait interface
(define-trait oracle-trait
  (
    (get-price (string-ascii 42) (response uint uint))
  ))