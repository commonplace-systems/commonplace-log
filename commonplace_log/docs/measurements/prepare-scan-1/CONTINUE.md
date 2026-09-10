# Two-case compatibility fixture continuation

Original validation1 remains native1/incomplete: required baseline performance RED accepted, candidate35tests2fail with33 retained passes including exact prepared-output/reduction metrics. No output moved or relabeled. See VALIDATION-1-REVIEW.json for hashes and disposition. Product source unchanged from ad39847.

The fixture catches raw errors, not rescued structs: missing Map.fetch! produces {:badkey,"entry_id"}. Both original and candidate propagate a case_clause wrapping scan's returned entry error because the existing find_or_build_entries lacks that error clause. The comparator accidentally treated the deliberately renamed baseline module as a behavioral difference. Normalize ONLY that module identity in the top MFA; retain kind/reason/function/arity. Correct both size-error and malformed-predecessor expectations to the actual original case_clause. Full stack equality remains unclaimed; retained type warning on hd(__STACKTRACE__) is not a runtime failure in these records.

Exactly the two failed cases are tagged. Continuation loads their10-case file with8excluded; no baseline or33-pass replay, no performance remeasurement. Same full source compilation and local library/synthetic fixture scope; no app/Worker/Docker/cloud/browser change.

Boss ONE fresh continuation after Plan no-blocker and ordinary gates, cwd /home/jes/commonplace-log-prepare-scan:

```sh
/usr/bin/env -i PATH=/usr/bin:/bin LANG=C.UTF-8 PYTHONDONTWRITEBYTECODE=1 /usr/bin/timeout --signal=TERM --kill-after=5s 100s /usr/bin/python3.12 -B commonplace_log/docs/measurements/prepare-scan-1/run-continue.py /home/jes/commonplace-log-prepare-scan/tmp/validation-2
```

Owner110s detached owned waiter, fresh private separate audit with original SHA/HEAD/argv/streams/rc/UTC retained in launch. Naturally absent validation2 (runner creates), no move/reuse. Child75/internal95/outer100+5; same owned process-group cleanup and input gates/PREPOST. Require10total0fail8excluded0skipped/native0/outer0/complete/equal valid inputs/known group absent/no timeout. First unexpected failure retain-stop/no retry. Passing two cases combines with retained33 and baseline control, never retroactively relabels validation1. No packaging or deployment grant.
