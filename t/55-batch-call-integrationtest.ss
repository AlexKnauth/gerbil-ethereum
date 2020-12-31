(export #t)

(import
  :std/format :std/iter :std/misc/list-builder :std/srfi/1 :std/sugar :std/test
  :clan/decimal :clan/debug :clan/json :clan/poo/poo :clan/persist/db
  ../ethereum ../known-addresses ../json-rpc ../nonce-tracker ../batch-call
  ../transaction ../tx-tracker
  ./signing-test ./30-transaction-integrationtest ./50-batch-send-integrationtest)

(def 55-batch-call-integrationtest
  (test-suite "integration test for ethereum/batch-call"
    (reset-nonce croesus) (DBG nonce: (peek-nonce croesus))
    (def trivial-logger (.@ (ensure-trivial-logger-contract croesus) contract-address))
    (test-case "trivial-logger works"
      (def receipt (post-transaction (call-function croesus trivial-logger (string->bytes "hello, world"))))
      (def logs (.@ receipt logs))
      (check-equal? (length logs) 1)
      (def log (car logs))
      (check-equal? [(.@ log address) (bytes->string (.@ log data))]
                    [trivial-logger "hello, world"]))
    (test-case "batch call works"
      (def batch-call-address (.@ (ensure-batch-call-contract croesus) contract-address))

      (def logger-balance-before (eth_getBalance trivial-logger 'pending))
      (def receipt (batch-call croesus [[trivial-logger 0 (string->bytes "Nothing here")]
                                        [trivial-logger (wei<-gwei 1) (string->bytes "Just lost one gwei")]]))
      (def logger-balance-after (eth_getBalance trivial-logger 'pending))
      ;; Check that the calls did deposit money onto the recipient contract
      (check-equal? (- logger-balance-after logger-balance-before) (wei<-gwei 1))
      ;; Check for two log entries from trivial-logger in the receipt
      (def logs (.@ receipt logs))
      (check-equal? (length logs) 2)
      (def (get-foo log) [(.@ log address) (bytes->string (.@ log data))])
      (check-equal? (get-foo (car logs)) [trivial-logger "Nothing here"])
      (check-equal? (get-foo (cadr logs)) [trivial-logger "Just lost one gwei"])
      )))