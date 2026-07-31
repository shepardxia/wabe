# Third-party code

`vqf.cpp` and `vqf.hpp` are copied from [dlaidig/vqf](https://github.com/dlaidig/vqf), MIT,
unmodified. Keep them that way: `git diff` after an update should show only upstream's changes.

    upstream  86ba56bdd3158b9b05f9f9fe5596866ba326438c   (2026-07-09)
    source    vqf/cpp/vqf.cpp, vqf/cpp/vqf.hpp

To update, re-copy both files and record the new commit above:

```bash
for f in vqf.cpp vqf.hpp; do
  curl -sLo "$f" "https://raw.githubusercontent.com/dlaidig/vqf/main/vqf/cpp/$f"
done
```

Then rebuild and replay the published capture before believing the result; the numbers to match
are in the repo's CLAUDE.md.

`shim.cpp` and `wabe_vqf.h` are wabe's own: an `extern "C"` wrapper so the C core can call the
C++ filter. Upstream ships no C API.
