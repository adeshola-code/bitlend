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