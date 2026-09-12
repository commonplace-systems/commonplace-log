# Provider-local restore binding results

Retained root-run receipts are referenced by path and SHA-256 below; bulky stdout/stderr remain in the local tmp directories and are not part of this summary.

## provider-restore-native-1
- Session: 86825
- Source: `b125f69300ddce1534edd5b281dac05e749ef6ca`
- Outcome: `1`; {"failure": "No test suite found", "input_hash_files_equal": true, "native_outer_rc": 1, "tests_executed": 0}
- Receipt hashes: `{'root-tool-completion.json': '625d1a33c6b3217adcc13eede6483770d0e4e26272a033b2aec9fba25acdddf9', 'result.json': 'dd5455c41d289cf610a5165d165c3fc2bb3c9f8c2366905e793a6f146e075ce2', 'native.rc': '4355a46b19d348dc2f57c046f8ef63d4538ebb936000f3c9ee954a27460dd865', 'verdict.rc': '4355a46b19d348dc2f57c046f8ef63d4538ebb936000f3c9ee954a27460dd865', 'pre.sha256': 'c7872554289c78be869082d4ef967547b687fde176fafac170e51706d2d17695', 'post.sha256': 'c7872554289c78be869082d4ef967547b687fde176fafac170e51706d2d17695', 'source-revision.txt': '12d4db1bbbd2a4dc3ec0403287bba2ea497ec7f2cbfa2a40a9a2022f592cdf6c'}`

## provider-restore-native-2
- Session: 2610
- Source: `f57924963e0fea2b4f7d7e1dcdd74dfc99e965ee`
- Outcome: `1`; {"failure": "No test suite found", "input_hash_files_equal": true, "native_outer_rc": 1, "root_config_prepost_sha256": "9ec0baaea3e76b4ae494252d4ea80c2dc956bcd4e63c841f84a3431b23df94ce", "tests_executed": 0}
- Receipt hashes: `{'root-tool-completion.json': 'e792cfdaf947c0a22a08a40e8d45fc8a61ce7608c56dfcf061e0874bb0b8d0e4', 'result.json': '62ce948f9cefd3ad7e11085db9f6a9a2ea8a2cac044a909ae27e357483e7faa4', 'native.rc': '4355a46b19d348dc2f57c046f8ef63d4538ebb936000f3c9ee954a27460dd865', 'verdict.rc': '4355a46b19d348dc2f57c046f8ef63d4538ebb936000f3c9ee954a27460dd865', 'pre.sha256': 'b74e5f2008b5c3b1668e6b48bad06f3aa1d9288230f68694626f740ebc9889ca', 'post.sha256': 'b74e5f2008b5c3b1668e6b48bad06f3aa1d9288230f68694626f740ebc9889ca', 'source-revision.txt': 'bd6348a5c2b2b5decbea1624f6e19d2ef2f1c679254e15bd0b30f23cd6688edd'}`

## provider-restore-diagnostic-1
- Session: 73833
- Source: `be01411f0bc97f28fa42d720a62ab49f2421ebd5`
- Outcome: `1`; {"control_tests_passed": 6, "finding": "Target externalized as mf_vitest_force=Data; installed miniflare unanchored **/*.bin matcher matches restore.binding.workers.test.ts", "input_hash_files_equal": true, "native_outer_rc": 1, "target_tests_executed": 0}
- Receipt hashes: `{'root-tool-completion.json': 'bb0a4e068a41e9443c936b9a9571dace44fe2d99fa58b8786b0aa2cc68c704e4', 'result.json': '22daacc32293318a13c66ff4082ec6c0edc01298d81a7b03eaf217141eccbd7c', 'native.rc': '4355a46b19d348dc2f57c046f8ef63d4538ebb936000f3c9ee954a27460dd865', 'verdict.rc': '4355a46b19d348dc2f57c046f8ef63d4538ebb936000f3c9ee954a27460dd865', 'pre.sha256': '6fbe8ab6078295307d642be65fc307cc5b0ca8693aee9ce2febec01f11f60ff1', 'post.sha256': '6fbe8ab6078295307d642be65fc307cc5b0ca8693aee9ce2febec01f11f60ff1', 'source-revision.txt': 'ad52213acdf705ad9d4cd4a93e08550b85683067eae17cfde904c12adf2e017d'}`

## provider-restore-native-3
- Session: 50241
- Source: `5aac3e6356d850d5b9b3b671123473c32226583`
- Outcome: `1`; {"failed": 1, "failure": "Test-only corruption UPDATE rejected by immutable entry trigger before restore assertion", "input_hash_files_equal": true, "native_outer_rc": 1, "passed": 3, "tests": 4}
- Receipt hashes: `{'root-tool-completion.json': '8251fe4f86245eb06ec7774adc3d04edb5df06dd74be126fc2857463e9c8fcab', 'result.json': '475305ecd660cc9e17da4ddebfa440ae7da5538bd36053493788bc5407d8487e', 'native.rc': '4355a46b19d348dc2f57c046f8ef63d4538ebb936000f3c9ee954a27460dd865', 'verdict.rc': '4355a46b19d348dc2f57c046f8ef63d4538ebb936000f3c9ee954a27460dd865', 'pre.sha256': '06df4aecc8f52148e6454fb25c6aa0f085b89fb36336576fae96768becbf54a6', 'post.sha256': '06df4aecc8f52148e6454fb25c6aa0f085b89fb36336576fae96768becbf54a6', 'source-revision.txt': 'c5f61e718f89ee43bd9f5345c517810d9912ef90a95fe749c00cf847e087314b'}`

## provider-restore-native-continuation-1
- Session: 98969
- Source: `17cc85877843a69fd845a0719a9aa10d8b85c9e9`
- Outcome: `0`; {"continuation_runner_prepost_sha256": "db1dfc74d81c10f1359071e30815f4a8a625a6a2150f4399e101ce007bde10a7", "failed": 0, "input_hash_files_equal": true, "native_outer_rc": 0, "passed": 1, "root_config_prepost_sha256": "9ec0baaea3e76b4ae494252d4ea80c2dc956bcd4e63c841f84a3431b23df94ce", "skipped_by_exact_filter": 3, "tests_defined": 4}
- Receipt hashes: `{'root-tool-completion.json': 'e0c08e45b9333e0d2d5dd8b4da2220786e26de36b238b499508b9d80519f6d0b', 'result.json': '084897ebc3b46b28c67f2b8f8733a6ab7922971bc4df34affa024d7871624e75', 'native.rc': '9a271f2a916b0b6ee6cecb2426f0b3206ef074578be55d9bc94f6f3fe3ab86aa', 'verdict.rc': '9a271f2a916b0b6ee6cecb2426f0b3206ef074578be55d9bc94f6f3fe3ab86aa', 'pre.sha256': 'c3de3486ccd36ed52dcecea42aab3ebd9d78a323b146b5541336ae7cdb6d4f1e', 'post.sha256': 'c3de3486ccd36ed52dcecea42aab3ebd9d78a323b146b5541336ae7cdb6d4f1e', 'source-revision.txt': '0a8c5dd662222958e17f7be52d4f1061f8802b18099a9dea77977f6e2349f256'}`

## Scope limits

- Internal RealmStore SQLite only; no HTTP or auth/public grant.
- Sidecar/provider lane is not implemented.
- Manifest byte-array amplification and the 16 MiB load boundary were not stress-tested.
