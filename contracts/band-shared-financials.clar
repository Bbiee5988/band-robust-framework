;; band-shared-financials.clar
;; Band Shared Financial Management - Core Contract

;; This contract manages band member financial collaboration, tracking shared expenses, 
;; income allocation, and transparent financial settlements on the Stacks blockchain.

;; =============== Error Constants ===============

(define-constant ERR-NOT-AUTHORIZED (err u1001))
(define-constant ERR-GROUP-EXISTS (err u1002))
(define-constant ERR-GROUP-NOT-FOUND (err u1003))
(define-constant ERR-MEMBER-NOT-IN-GROUP (err u1004))
(define-constant ERR-MEMBER-ALREADY-IN-GROUP (err u1005))
(define-constant ERR-EXPENSE-NOT-FOUND (err u1006))
(define-constant ERR-INSUFFICIENT-FUNDS (err u1007))
(define-constant ERR-INVALID-AMOUNT (err u1008))
(define-constant ERR-INVALID-ALLOCATION (err u1009))
(define-constant ERR-INVALID-EXPENSE-TYPE (err u1010))
(define-constant ERR-MEMBER-HAS-BALANCE (err u1011))
(define-constant ERR-INVALID-PAYMENT (err u1012))
(define-constant ERR-INVALID-PARAMETER (err u1013))

;; =============== Data Structures ===============

;; Keeps track of all band group IDs and their creators
(define-map band-groups
  { group-id: uint }
  { 
    name: (string-ascii 100),
    creator: principal,
    created-at: uint,
    active: bool
  }
)

;; Tracks membership of musicians in bands
(define-map band-members
  { group-id: uint, member: principal }
  {
    joined-at: uint,
    allocation-bps: uint,   ;; Basis points for income/expense allocation (100 = 1%, 10000 = 100%)
    active: bool
  }
)

;; Maps band group IDs to a list of member principals
(define-map band-member-list
  { group-id: uint }
  { members: (list 20 principal) }
)

;; Stores expense and income information
(define-map financial-entries
  { group-id: uint, entry-id: uint }
  {
    name: (string-ascii 100),
    amount: uint,
    paid-by: principal,
    entry-type: (string-ascii 20),   ;; "income", "expense", "royalty"
    recurrence-period: uint,          ;; 0 for one-time, otherwise period in blocks
    created-at: uint,
    allocation-type: (string-ascii 10), ;; "equal" or "custom"
    settled: bool
  }
)

;; Custom income/expense allocations
(define-map entry-allocations
  { group-id: uint, entry-id: uint, member: principal }
  { allocation-bps: uint }
)

;; Tracks running balances between members
(define-map member-balances
  { group-id: uint, from-member: principal, to-member: principal }
  { amount: uint }
)

;; Tracks payment settlements between members
(define-map settlements
  { group-id: uint, settlement-id: uint }
  {
    from-member: principal,
    to-member: principal,
    amount: uint,
    timestamp: uint,
    tx-id: (optional (buff 32))
  }
)

;; Counter for band group IDs
(define-data-var next-group-id uint u1)

;; Counters for entry and settlement IDs (per group)
(define-map group-counters
  { group-id: uint }
  { 
    next-entry-id: uint,
    next-settlement-id: uint
  }
)

;; =============== Private Helper Functions ===============

(define-private (get-next-group-id)
  (let ((current-id (var-get next-group-id)))
    (var-set next-group-id (+ current-id u1))
    current-id
  )
)

(define-private (get-next-entry-id (group-id uint))
  (let (
    (counters (default-to { next-entry-id: u1, next-settlement-id: u1 } 
                (map-get? group-counters { group-id: group-id })))
    (next-id (get next-entry-id counters))
  )
    (map-set group-counters 
      { group-id: group-id } 
      (merge counters { next-entry-id: (+ next-id u1) })
    )
    next-id
  )
)

(define-private (get-next-settlement-id (group-id uint))
  (let (
    (counters (default-to { next-entry-id: u1, next-settlement-id: u1 } 
                (map-get? group-counters { group-id: group-id })))
    (next-id (get next-settlement-id counters))
  )
    (map-set group-counters 
      { group-id: group-id } 
      (merge counters { next-settlement-id: (+ next-id u1) })
    )
    next-id
  )
)

;; Check if a user is a member of a group
(define-private (is-member (group-id uint) (user principal))
  (match (map-get? band-members { group-id: group-id, member: user })
    member (and (get active member) true)
    false
  )
)

;; Check if user is authorized to manage a group (currently only the creator)
(define-private (is-group-admin (group-id uint) (user principal))
  (match (map-get? band-groups { group-id: group-id })
    group (is-eq (get creator group) user)
    false
  )
)

;; Calculate equal allocation in basis points for all members
(define-private (calculate-equal-allocation (group-id uint))
  (match (map-get? band-member-list { group-id: group-id })
    member-list (let ((member-count (len (get members member-list))))
      (if (> member-count u0)
        (/ u10000 member-count)  ;; Equal division (10000 basis points = 100%)
        u0
      ))
    u0
  )
)

;; Update the balance between two members
(define-private (update-balance (group-id uint) (from principal) (to principal) (amount uint))
  (let (
    (current-balance (default-to { amount: u0 } 
                      (map-get? member-balances { group-id: group-id, from-member: from, to-member: to })))
    (new-amount (+ (get amount current-balance) amount))
  )
    (map-set member-balances
      { group-id: group-id, from-member: from, to-member: to }
      { amount: new-amount }
    )
    (ok true)
  )
)

;; Add member to the band member list
(define-private (add-to-member-list (group-id uint) (new-member principal))
  (let (
    (current-list-struct (default-to { members: (list) } 
                   (map-get? band-member-list { group-id: group-id })))
    (updated-members-list (unwrap! (as-max-len? (append (get members current-list-struct) new-member) u20) ERR-INVALID-PARAMETER))
  )
    (map-set band-member-list 
      { group-id: group-id } 
      { members: updated-members-list }
    )
    (ok true)
  )
)

;; Helper for checking member balances
(define-private (check-member-balance-accumulator (other-member principal) (params (tuple (group-id uint) (member principal) (has-balance bool))))
  (let ((g-id (get group-id params))
        (current-member (get member params))
        (current-has-balance (get has-balance params)))
    (if current-has-balance
      true ;; If a balance was already found, no need to check further
      (let (
        (from-balance (default-to { amount: u0 } 
                       (map-get? member-balances { 
                         group-id: g-id, 
                         from-member: current-member, 
                         to-member: other-member 
                       })))
        (to-balance (default-to { amount: u0 } 
                     (map-get? member-balances { 
                       group-id: g-id, 
                       from-member: other-member, 
                       to-member: current-member 
                     })))
      )
        (or (> (get amount from-balance) u0) (> (get amount to-balance) u0))
      )
    )
  )
)

;; =============== Read-Only Functions ===============

;; Get band group information
(define-read-only (get-group (group-id uint))
  (map-get? band-groups { group-id: group-id })
)

;; Get member information for a group
(define-read-only (get-group-member (group-id uint) (member principal))
  (map-get? band-members { group-id: group-id, member: member })
)

;; Get all members of a group
(define-read-only (get-group-members (group-id uint))
  (map-get? band-member-list { group-id: group-id })
)

;; Get a financial entry's details
(define-read-only (get-financial-entry (group-id uint) (entry-id uint))
  (map-get? financial-entries { group-id: group-id, entry-id: entry-id })
)

;; Get a member's allocation for a specific entry
(define-read-only (get-entry-allocation (group-id uint) (entry-id uint) (member principal))
  (map-get? entry-allocations { group-id: group-id, entry-id: entry-id, member: member })
)

;; Get the balance between two members
(define-read-only (get-member-balance (group-id uint) (from principal) (to principal))
  (default-to { amount: u0 } 
    (map-get? member-balances { group-id: group-id, from-member: from, to-member: to })
  )
)

;; Get a settlement's details
(define-read-only (get-settlement (group-id uint) (settlement-id uint))
  (map-get? settlements { group-id: group-id, settlement-id: settlement-id })
)

;; Check if a group exists
(define-read-only (group-exists (group-id uint))
  (is-some (map-get? band-groups { group-id: group-id }))
)

;; =============== Public Functions ===============

;; Create a new band group
(define-public (create-group (name (string-ascii 100)))
  (let (
    (group-id (get-next-group-id))
    (caller tx-sender)
    (block-height block-height)
  )
    ;; Set group details
    (map-set band-groups 
      { group-id: group-id }
      { 
        name: name,
        creator: caller,
        created-at: block-height,
        active: true
      }
    )
    
    ;; Initialize counters for this group
    (map-set group-counters
      { group-id: group-id }
      { next-entry-id: u1, next-settlement-id: u1 }
    )
    
    ;; Add creator as first member with 100% allocation
    (map-set band-members
      { group-id: group-id, member: caller }
      {
        joined-at: block-height,
        allocation-bps: u10000,  ;; 100% allocation until more members are added
        active: true
      }
    )
    
    ;; Initialize member list with the creator
    (map-set band-member-list
      { group-id: group-id }
      { members: (list caller) }
    )
    
    (ok group-id)
  )
)

;; Add a member to a band group
(define-public (add-member (group-id uint) (new-member principal))
  (let (
    (caller tx-sender)
    (block-height block-height)
  )
    ;; Verify caller is admin
    (asserts! (is-group-admin group-id caller) ERR-NOT-AUTHORIZED)
    
    ;; Verify group exists
    (asserts! (group-exists group-id) ERR-GROUP-NOT-FOUND)
    
    ;; Verify new member isn't already a member
    (asserts! (not (is-member group-id new-member)) ERR-MEMBER-ALREADY-IN-GROUP)
    
    ;; Add member with equal allocation
    (try! (add-to-member-list group-id new-member))
    
    ;; Calculate equal allocation for all members
    (let ((equal-allocation (calculate-equal-allocation group-id)))
      ;; Update all existing members to have equal allocation
      (map-set band-members
        { group-id: group-id, member: new-member }
        {
          joined-at: block-height,
          allocation-bps: equal-allocation,
          active: true
        }
      )
      
      ;; Return the result
      (ok true)
    )
  )
)

;; Update a member's allocation percentage
(define-public (update-member-allocation (group-id uint) (member principal) (allocation-bps uint))
  (let (
    (caller tx-sender)
  )
    ;; Verify caller is admin
    (asserts! (is-group-admin group-id caller) ERR-NOT-AUTHORIZED)
    
    ;; Verify group exists
    (asserts! (group-exists group-id) ERR-GROUP-NOT-FOUND)
    
    ;; Verify member exists in group
    (asserts! (is-member group-id member) ERR-MEMBER-NOT-IN-GROUP)
    
    ;; Verify allocation is valid (0-10000)
    (asserts! (<= allocation-bps u10000) ERR-INVALID-ALLOCATION)
    
    ;; Currently just a pass-through, can be expanded
    (ok true)
  )
)

;; Settle a payment between members
(define-public (settle-payment (group-id uint) (to-member principal) (amount uint))
  (let (
    (caller tx-sender)
    (settlement-id (get-next-settlement-id group-id))
    (block-height block-height)
  )
    ;; Verify members are in the group
    (asserts! (is-member group-id caller) ERR-MEMBER-NOT-IN-GROUP)
    (asserts! (is-member group-id to-member) ERR-MEMBER-NOT-IN-GROUP)
    
    ;; Verify group exists
    (asserts! (group-exists group-id) ERR-GROUP-NOT-FOUND)
    
    ;; Verify amount is greater than zero
    (asserts! (> amount u0) ERR-INVALID-AMOUNT)
    
    ;; Get current balance
    (let (
      (current-balance (get amount (get-member-balance group-id caller to-member)))
    )
      ;; Verify caller has sufficient balance to settle
      (asserts! (>= current-balance amount) ERR-INSUFFICIENT-FUNDS)
      
      ;; Update balance (reduce what caller owes)
      (map-set member-balances
        { group-id: group-id, from-member: caller, to-member: to-member }
        { amount: (- current-balance amount) }
      )
      
      ;; Record the settlement
      (map-set settlements
        { group-id: group-id, settlement-id: settlement-id }
        {
          from-member: caller,
          to-member: to-member,
          amount: amount,
          timestamp: block-height,
          tx-id: none
        }
      )
      
      (ok settlement-id)
    )
  )
)