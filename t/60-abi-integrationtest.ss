(export #t)

(import
  :gerbil/gambit/os
  :std/misc/list :std/misc/ports :std/misc/process :std/srfi/1 :std/sugar :std/test :std/text/hex
  :clan/debug :clan/list :clan/path :clan/path-config :clan/poo/poo
  ../hex ../types ../ethereum ../signing ../network-config
  ../json-rpc ../nonce-tracker ../transaction ../abi ../tx-tracker
  ./signing-test ./30-transaction-integrationtest)

(def (compile-solidity src dstdir)
  (def srcdir (path-directory src))
  (def srcfile (path-strip-directory src))
  (create-directory* dstdir)
  (run-process/batch ["solc" "--optimize" "--bin" "--abi" "-o" dstdir "--overwrite" srcfile]
    directory: srcdir)
  (void))

(def gerbil-ethereum-src (or (getenv "GERBIL_ETHEREUM_SRC" #f)
                             (source-directory)))

;; TODO: either install the damn file with the build, or be able to locate it via nix or gxpkg
(def test-contract-source (subpath gerbil-ethereum-src "t/test_contract.sol"))
(def test-contract-bin (run-path "t/ethereum/HelloWorld.bin"))

(def (modification-time file)
  (let/cc return
    (def info (with-catch false (cut file-info file #t)))
    (time->seconds (file-info-last-modification-time info))))

(def (test-contract-bytes)
  (unless (and (file-exists? test-contract-bin)
               (<= (or (modification-time test-contract-source) +inf.0)
                   (or (modification-time test-contract-bin) -inf.0)))
    (compile-solidity test-contract-source (path-parent test-contract-bin)))
  (hex-decode (read-file-string test-contract-bin)))

(def contract #f)

(def (ensure-contract)
  (unless contract
    (let (receipt (post-transaction (create-contract croesus (test-contract-bytes))))
      (set! contract (.@ receipt contractAddress)))))

(defrule (check-equal-bytes? x y) (check-equal? (0x<-bytes x) (0x<-bytes y)))

(def 60-abi-integrationtest
  (test-suite "integration test for ethereum/abi"
    (reset-nonce croesus) (DBG nonce: (peek-nonce croesus))
    (unless (ethereum-mantis?)
      (test-case "Contract creation failure due to insufficient gas"
        ;; Mantis never accepts the transaction, and even logs a message why it won't,
        ;; but its JSON RPC API doesn't give us any way to tell it's failed.
        (check-exception (post-transaction (create-contract croesus (test-contract-bytes) gas: 21000))
                         (match <> ((TransactionStatus-TxFailed (vector _ exn))
                                    (if (ethereum-mantis?)
                                      (and (TransactionRejected? exn)
                                           (equal? (TransactionRejected-receipt exn)
                                                   "Reason unknown (nonce didn't change)"))
                                      (IntrinsicGasTooLow? exn)))
                                (_ #f)))
        ;; Mantis never accepts the transaction, and doesn't even log a message why it won't,
        ;; but its JSON RPC API doesn't give us any way to tell it's failed.
        (check-exception (post-transaction (create-contract croesus (test-contract-bytes) gas: 100000))
                         (match <> ((TransactionStatus-TxFailed (vector _ (? TransactionRejected?))) #t)
                                (_ #f)))))
    (test-case "Call contract function hello with no argument"
      (ensure-contract)
      (def pretx (call-function croesus contract
                                (bytes<-ethereum-function-call ["hello"] [])))
      (def receipt (post-transaction pretx))
      (def block-number (.@ receipt blockNumber))
      (def data (eth_call (CallParameters<-PreTransaction pretx) (1- block-number)))
      (check-equal-bytes? data (ethabi-encode [String] ["Hello, World!"])))
    (test-case "call contract function mul42 with one number argument"
      (def pretx (call-function croesus contract
                                (bytes<-ethereum-function-call ["mul42" UInt256] [47])))
      (def receipt (post-transaction pretx))
      (def block-number (.@ receipt blockNumber))
      (def data (eth_call (CallParameters<-PreTransaction pretx) (1- block-number)))
      (check-equal-bytes? data (ethabi-encode [UInt256] [1974])))
    (test-case "call contract function greetings with one string argument"
      (def pretx (call-function croesus contract
                                (bytes<-ethereum-function-call ["greetings" String] ["Croesus"])))
      (def receipt (post-transaction pretx))
      (def block-number (.@ receipt blockNumber))
      (def logs (.@ receipt logs))
      (def receipt-log (first-and-only logs))
      (def log-contract-address (.@ receipt-log address))
      (check-equal? log-contract-address contract)
      (def topic-event (first-and-only (.@ receipt-log topics)))
      (check-equal-bytes? topic-event (digest<-function-signature ["greetingsEvent" String]))
      ;; the log data is the encoding of the parameter passed to the event
      (def data (.@ receipt-log data))
      (def result (eth_call (CallParameters<-PreTransaction pretx) (1- block-number)))
      (check-equal-bytes? data result)
      (check-equal-bytes? data (ethabi-encode [String] ["Greetings, Croesus"])))))

;; TODO: add a stateful function, and check the behavior of eth-call wrt block-number
;; TODO: test the parsing of the HelloWorld.abi JSON descriptor