(define-constant CONTRACT_OWNER tx-sender)
(define-constant ERR_UNAUTHORIZED (err u100))
(define-constant ERR_INVALID_IMPLEMENTATION (err u101))
(define-constant ERR_UPGRADE_FAILED (err u102))
(define-constant ERR_STORAGE_COLLISION (err u103))
(define-constant ERR_INVALID_SELECTOR (err u104))
(define-constant ERR_NO_ROLLBACK_AVAILABLE (err u105))
(define-constant ERR_ROLLBACK_WINDOW_EXPIRED (err u106))
(define-constant ERR_PROPOSAL_NOT_FOUND (err u107))
(define-constant ERR_ALREADY_SIGNED (err u108))
(define-constant ERR_INSUFFICIENT_SIGNATURES (err u109))
(define-constant ERR_PROPOSAL_EXPIRED (err u110))

(define-data-var implementation-address principal CONTRACT_OWNER)
(define-data-var admin principal CONTRACT_OWNER)
(define-data-var upgrade-delay uint u86400)
(define-data-var pending-implementation (optional principal) none)
(define-data-var upgrade-timestamp (optional uint) none)

(define-map storage-slots uint uint)
(define-map function-selectors (string-ascii 32) principal)
(define-map implementation-versions principal uint)
(define-map authorized-upgraders principal bool)

(define-data-var proxy-initialized bool false)
(define-data-var total-upgrades uint u0)
(define-data-var emergency-pause bool false)
(define-data-var rollback-window uint u172800)

(define-map implementation-history uint {impl: principal, timestamp: uint})
(define-data-var rollback-history-count uint u0)

(define-data-var multisig-threshold uint u2)
(define-data-var proposal-expiry-time uint u1440)
(define-data-var proposal-counter uint u0)

(define-map multisig-signers principal bool)
(define-map governance-proposals uint {
  proposal-type: (string-ascii 32),
  proposer: principal,
  target: (optional principal),
  value: (optional uint),
  data: (optional (buff 256)),
  created-at: uint,
  expires-at: uint,
  executed: bool,
  signatures-count: uint
})
(define-map proposal-signatures {proposal-id: uint, signer: principal} bool)

(define-read-only (get-implementation)
  (var-get implementation-address))

(define-read-only (get-admin)
  (var-get admin))

(define-read-only (get-storage-slot (slot uint))
  (default-to u0 (map-get? storage-slots slot)))

(define-read-only (get-function-implementation (selector (string-ascii 32)))
  (map-get? function-selectors selector))

(define-read-only (get-implementation-version (impl principal))
  (default-to u0 (map-get? implementation-versions impl)))

(define-read-only (is-authorized-upgrader (user principal))
  (default-to false (map-get? authorized-upgraders user)))

(define-read-only (get-pending-upgrade)
  {
    implementation: (var-get pending-implementation),
    timestamp: (var-get upgrade-timestamp)
  })

(define-read-only (get-proxy-state)
  {
    implementation: (var-get implementation-address),
    admin: (var-get admin),
    initialized: (var-get proxy-initialized),
    total-upgrades: (var-get total-upgrades),
    emergency-pause: (var-get emergency-pause),
    upgrade-delay: (var-get upgrade-delay),
    rollback-window: (var-get rollback-window)
  })

(define-read-only (get-rollback-history (index uint))
  (map-get? implementation-history index))

(define-read-only (get-rollback-history-count)
  (var-get rollback-history-count))

(define-read-only (is-multisig-signer (signer principal))
  (default-to false (map-get? multisig-signers signer)))

(define-read-only (get-multisig-threshold)
  (var-get multisig-threshold))

(define-read-only (get-proposal (proposal-id uint))
  (map-get? governance-proposals proposal-id))

(define-read-only (has-signed-proposal (proposal-id uint) (signer principal))
  (default-to false (map-get? proposal-signatures {proposal-id: proposal-id, signer: signer})))

(define-read-only (get-proposal-counter)
  (var-get proposal-counter))

(define-public (initialize-proxy (initial-implementation principal))
  (begin
    (asserts! (not (var-get proxy-initialized)) ERR_UNAUTHORIZED)
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_UNAUTHORIZED)
    (var-set implementation-address initial-implementation)
    (var-set proxy-initialized true)
    (map-set implementation-versions initial-implementation u1)
    (map-set authorized-upgraders CONTRACT_OWNER true)
    (ok true)))

(define-public (propose-upgrade (new-implementation principal))
  (begin
    (asserts! (var-get proxy-initialized) ERR_UNAUTHORIZED)
    (asserts! (not (var-get emergency-pause)) ERR_UNAUTHORIZED)
    (asserts! (or (is-eq tx-sender (var-get admin)) 
                  (is-authorized-upgrader tx-sender)) ERR_UNAUTHORIZED)
    (asserts! (not (is-eq new-implementation (var-get implementation-address))) ERR_INVALID_IMPLEMENTATION)
    (var-set pending-implementation (some new-implementation))
    (var-set upgrade-timestamp (some (+ stacks-block-height (var-get upgrade-delay))))
    (ok true)))

(define-public (execute-upgrade)
  (let ((pending-impl (var-get pending-implementation))
        (upgrade-time (var-get upgrade-timestamp)))
    (asserts! (var-get proxy-initialized) ERR_UNAUTHORIZED)
    (asserts! (not (var-get emergency-pause)) ERR_UNAUTHORIZED)
    (asserts! (or (is-eq tx-sender (var-get admin)) 
                  (is-authorized-upgrader tx-sender)) ERR_UNAUTHORIZED)
    (asserts! (is-some pending-impl) ERR_INVALID_IMPLEMENTATION)
    (asserts! (is-some upgrade-time) ERR_UPGRADE_FAILED)
    (asserts! (>= stacks-block-height (unwrap-panic upgrade-time)) ERR_UPGRADE_FAILED)
    (let ((new-impl (unwrap-panic pending-impl))
          (current-impl (var-get implementation-address)))
      (map-set implementation-history (var-get rollback-history-count) 
               {impl: current-impl, timestamp: stacks-block-height})
      (var-set rollback-history-count (+ (var-get rollback-history-count) u1))
      (var-set implementation-address new-impl)
      (var-set pending-implementation none)
      (var-set upgrade-timestamp none)
      (var-set total-upgrades (+ (var-get total-upgrades) u1))
      (map-set implementation-versions new-impl 
               (+ (get-implementation-version new-impl) u1))
      (ok true))))

(define-public (cancel-upgrade)
  (begin
    (asserts! (var-get proxy-initialized) ERR_UNAUTHORIZED)
    (asserts! (is-eq tx-sender (var-get admin)) ERR_UNAUTHORIZED)
    (var-set pending-implementation none)
    (var-set upgrade-timestamp none)
    (ok true)))

(define-public (emergency-pause-toggle)
  (begin
    (asserts! (is-eq tx-sender (var-get admin)) ERR_UNAUTHORIZED)
    (var-set emergency-pause (not (var-get emergency-pause)))
    (ok (var-get emergency-pause))))

(define-public (change-admin (new-admin principal))
  (begin
    (asserts! (is-eq tx-sender (var-get admin)) ERR_UNAUTHORIZED)
    (var-set admin new-admin)
    (ok true)))

(define-public (set-upgrade-delay (new-delay uint))
  (begin
    (asserts! (is-eq tx-sender (var-get admin)) ERR_UNAUTHORIZED)
    (asserts! (>= new-delay u3600) ERR_UNAUTHORIZED)
    (var-set upgrade-delay new-delay)
    (ok true)))

(define-public (authorize-upgrader (user principal))
  (begin
    (asserts! (is-eq tx-sender (var-get admin)) ERR_UNAUTHORIZED)
    (map-set authorized-upgraders user true)
    (ok true)))

(define-public (revoke-upgrader (user principal))
  (begin
    (asserts! (is-eq tx-sender (var-get admin)) ERR_UNAUTHORIZED)
    (map-delete authorized-upgraders user)
    (ok true)))

(define-public (delegate-call (selector (string-ascii 32)) (data (buff 1024)))
  (let ((target-impl (get-function-implementation selector)))
    (asserts! (var-get proxy-initialized) ERR_UNAUTHORIZED)
    (asserts! (not (var-get emergency-pause)) ERR_UNAUTHORIZED)
    (asserts! (is-some target-impl) ERR_INVALID_SELECTOR)
    (simulate-delegatecall (unwrap-panic target-impl) selector data)))

(define-private (simulate-delegatecall (target principal) (selector (string-ascii 32)) (data (buff 1024)))
  (begin
    (try! (set-storage-slot u1 (len data)))
    (try! (set-storage-slot u2 stacks-block-height))
    (ok {
      target: target,
      selector: selector,
      data-length: (len data),
      execution-block: stacks-block-height
    })))

(define-public (set-storage-slot (slot uint) (value uint))
  (begin
    (asserts! (var-get proxy-initialized) ERR_UNAUTHORIZED)
    (asserts! (or (is-eq tx-sender (var-get implementation-address))
                  (is-eq tx-sender (var-get admin))) ERR_UNAUTHORIZED)
    (asserts! (< slot u1000) ERR_STORAGE_COLLISION)
    (map-set storage-slots slot value)
    (ok true)))

(define-public (register-function (selector (string-ascii 32)) (implementation principal))
  (begin
    (asserts! (is-eq tx-sender (var-get admin)) ERR_UNAUTHORIZED)
    (map-set function-selectors selector implementation)
    (ok true)))

(define-public (batch-set-storage (slots (list 10 {slot: uint, value: uint})))
  (begin
    (asserts! (var-get proxy-initialized) ERR_UNAUTHORIZED)
    (asserts! (or (is-eq tx-sender (var-get implementation-address))
                  (is-eq tx-sender (var-get admin))) ERR_UNAUTHORIZED)
    (ok (map set-storage-batch-item slots))))

(define-private (set-storage-batch-item (item {slot: uint, value: uint}))
  (begin
    (map-set storage-slots (get slot item) (get value item))
    true))

(define-public (simulate-upgrade-with-storage-migration (new-impl principal) (migration-data (list 20 {slot: uint, value: uint})))
  (begin
    (asserts! (is-eq tx-sender (var-get admin)) ERR_UNAUTHORIZED)
    (asserts! (var-get proxy-initialized) ERR_UNAUTHORIZED)
    (try! (propose-upgrade new-impl))
    (map set-storage-batch-item migration-data)
    (ok true)))

(define-read-only (check-storage-layout (slots (list 10 uint)))
  (ok (map get-storage-slot slots)))

(define-read-only (get-upgrade-history)
  {
    current-implementation: (var-get implementation-address),
    total-upgrades: (var-get total-upgrades),
    pending-upgrade: (var-get pending-implementation),
    upgrade-delay: (var-get upgrade-delay)
  })

(define-public (simulate-proxy-call (target-function (string-ascii 32)) (call-data (buff 512)))
  (let ((impl (var-get implementation-address)))
    (asserts! (var-get proxy-initialized) ERR_UNAUTHORIZED)
    (asserts! (not (var-get emergency-pause)) ERR_UNAUTHORIZED)
    (try! (set-storage-slot u999 (+ (get-storage-slot u999) u1)))
    (ok {
      implementation: impl,
      function: target-function,
      call-count: (get-storage-slot u999),
      stacks-block-height: stacks-block-height
    })))

(define-public (rollback-implementation (history-index uint))
  (let ((history-entry (map-get? implementation-history history-index)))
    (asserts! (var-get proxy-initialized) ERR_UNAUTHORIZED)
    (asserts! (not (var-get emergency-pause)) ERR_UNAUTHORIZED)
    (asserts! (is-eq tx-sender (var-get admin)) ERR_UNAUTHORIZED)
    (asserts! (is-some history-entry) ERR_NO_ROLLBACK_AVAILABLE)
    (let ((entry (unwrap-panic history-entry)))
      (asserts! (< (- stacks-block-height (get timestamp entry)) (var-get rollback-window)) ERR_ROLLBACK_WINDOW_EXPIRED)
      (var-set implementation-address (get impl entry))
      (var-set total-upgrades (+ (var-get total-upgrades) u1))
      (ok true))))

(define-public (set-rollback-window (new-window uint))
  (begin
    (asserts! (is-eq tx-sender (var-get admin)) ERR_UNAUTHORIZED)
    (asserts! (>= new-window u3600) ERR_UNAUTHORIZED)
    (var-set rollback-window new-window)
    (ok true)))

(define-public (emergency-rollback)
  (begin
    (asserts! (is-eq tx-sender (var-get admin)) ERR_UNAUTHORIZED)
    (asserts! (var-get proxy-initialized) ERR_UNAUTHORIZED)
    (asserts! (> (var-get rollback-history-count) u0) ERR_NO_ROLLBACK_AVAILABLE)
    (let ((last-index (- (var-get rollback-history-count) u1)))
      (let ((history-entry (map-get? implementation-history last-index)))
        (asserts! (is-some history-entry) ERR_NO_ROLLBACK_AVAILABLE)
        (let ((entry (unwrap-panic history-entry)))
          (var-set implementation-address (get impl entry))
          (var-set total-upgrades (+ (var-get total-upgrades) u1))
          (ok true))))))

(define-public (set-multisig-signer (signer principal) (authorized bool))
  (begin
    (asserts! (is-eq tx-sender (var-get admin)) ERR_UNAUTHORIZED)
    (if authorized
      (map-set multisig-signers signer true)
      (map-delete multisig-signers signer))
    (ok true)))

(define-public (set-multisig-threshold (new-threshold uint))
  (begin
    (asserts! (is-eq tx-sender (var-get admin)) ERR_UNAUTHORIZED)
    (asserts! (> new-threshold u0) ERR_UNAUTHORIZED)
    (var-set multisig-threshold new-threshold)
    (ok true)))

(define-public (create-proposal (proposal-type (string-ascii 32)) (target (optional principal)) (value (optional uint)) (data (optional (buff 256))))
  (let ((proposal-id (var-get proposal-counter)))
    (asserts! (is-multisig-signer tx-sender) ERR_UNAUTHORIZED)
    (map-set governance-proposals proposal-id {
      proposal-type: proposal-type,
      proposer: tx-sender,
      target: target,
      value: value,
      data: data,
      created-at: stacks-block-height,
      expires-at: (+ stacks-block-height (var-get proposal-expiry-time)),
      executed: false,
      signatures-count: u0
    })
    (var-set proposal-counter (+ proposal-id u1))
    (ok proposal-id)))

(define-public (sign-proposal (proposal-id uint))
  (let ((proposal (map-get? governance-proposals proposal-id)))
    (asserts! (is-multisig-signer tx-sender) ERR_UNAUTHORIZED)
    (asserts! (is-some proposal) ERR_PROPOSAL_NOT_FOUND)
    (asserts! (not (has-signed-proposal proposal-id tx-sender)) ERR_ALREADY_SIGNED)
    (let ((proposal-data (unwrap-panic proposal)))
      (asserts! (< stacks-block-height (get expires-at proposal-data)) ERR_PROPOSAL_EXPIRED)
      (asserts! (not (get executed proposal-data)) ERR_PROPOSAL_EXPIRED)
      (map-set proposal-signatures {proposal-id: proposal-id, signer: tx-sender} true)
      (map-set governance-proposals proposal-id 
               (merge proposal-data {signatures-count: (+ (get signatures-count proposal-data) u1)}))
      (ok true))))

(define-public (execute-multisig-proposal (proposal-id uint))
  (let ((proposal (map-get? governance-proposals proposal-id)))
    (asserts! (is-multisig-signer tx-sender) ERR_UNAUTHORIZED)
    (asserts! (is-some proposal) ERR_PROPOSAL_NOT_FOUND)
    (let ((proposal-data (unwrap-panic proposal)))
      (asserts! (< stacks-block-height (get expires-at proposal-data)) ERR_PROPOSAL_EXPIRED)
      (asserts! (not (get executed proposal-data)) ERR_PROPOSAL_EXPIRED)
      (asserts! (>= (get signatures-count proposal-data) (var-get multisig-threshold)) ERR_INSUFFICIENT_SIGNATURES)
      (map-set governance-proposals proposal-id (merge proposal-data {executed: true}))
      (ok true))))