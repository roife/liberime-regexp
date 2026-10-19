# liberime-regexp

`liberime-regexp` lets Emacs search and jump with lower-case Rime codes. For
example, searching for `ni` can match the Rime candidate `你`. It works with
built-in `isearch` and Avy, and integrates with Orderless and Evil search when
they are available.

Requirements: Emacs 27.1 or newer, [Avy](https://github.com/abo-abo/avy) 0.5.0
or newer, and [liberime](https://github.com/emacs-rime/liberime) 0.0.11 or newer,
with full-context search and session APIs.

## Installation

With `straight.el` and `use-package`:

```elisp
(use-package liberime-regexp
  :straight (liberime-regexp
             :type git
             :host github
             :repo "roife/liberime-regexp")
  :hook (liberime-after-start . liberime-regexp-enable))
```

## Avy

Enable Rime expansion for Avy's character commands:

```elisp
(liberime-regexp-avy-mode 1)
```

This remaps `avy-goto-char`, `avy-goto-char-in-line`, `avy-goto-char-2`, and
`avy-goto-char-timer`. The timer command accepts a complete Rime code, so
typing `ni` can jump to `你` or another visible Rime candidate.

## Options

Customize these variables with `M-x customize-group RET liberime-regexp` or
set them in your Emacs configuration.

| Variable | Default | Description |
| --- | ---: | --- |
| `liberime-regexp-max-code-length` | `0` | Maximum code length to expand. `0` means no limit. |
| `liberime-regexp-candidate-limit` | `100` | Maximum candidates examined for one code. `nil` or a non-positive value means no limit. |
| `liberime-regexp-cache-size` | `256` | Maximum number of cached queries, with oldest entries evicted first. A non-positive value disables caching. |
| `liberime-regexp-omit-code-separators` | `t` | Allow whitespace between adjacent Rime codes to match nothing. |

Candidate lookup reuses a separate session synchronized with the active
schema and its switch options, leaving the current composition untouched.

## Chinese word segmentation

Segmentation additionally requires Emacs native JSON support and librime with
[librime-lua](https://github.com/hchunhui/librime-lua), including
`ReverseLookup`, `Component.Translator`, and `Phrase.weight`. It uses the
static dictionary of the active input schema; an optional schema argument
selects another dictionary without switching the input method.

```elisp
(liberime-regexp-segment "研究生命起源")
;; => ((0 . 2) (2 . 6)), with the current rime_ice dictionary
(liberime-regexp-split-string "研究生命起源")
;; => ("研究" "生命起源")
(liberime-regexp-segment-mode 1)
```

Ranges are zero-based character offsets with an exclusive end, not UTF-8
byte offsets. Non-Han words follow the current buffer's syntax table;
whitespace and punctuation are omitted. `liberime-regexp-segment-mode`
globally remaps `forward-word`, `backward-word`, `kill-word`,
`backward-kill-word`, and `mark-word`. `liberime-regexp-word-at-point`
returns the containing word (or the preceding word at its end). Movement
respects narrowing and segments the entire contiguous Han run so that
forward and backward movement use the same boundaries. Evil motions and
text objects are not remapped.

### Rime configuration

The local Home Manager module `~/.config/nix/home/rime.nix` owns deployment:
it links `rime/liberime_regexp_segment.lua` from `~/code/liberime-regexp`
into Rime's `lua/` directory and generates these schemas:

- `liberime_regexp_segment`: an isolated Lua gateway registered after the
  normal input schema in `default/schema_list`. It uses `speller`,
  `abc_segmentor`, `lua_translator@*liberime_regexp_segment`, and an alphabet
  containing lowercase ASCII letters and digits.
- `liberime_regexp_segment_rime_ice`: a dependency of the gateway, using
  `rime_ice` with its own prism, empty spelling algebra, and `" '"` as the
  delimiter. User dictionaries, completion, and contextual suggestions
  are disabled. The gateway maps `segment/backends/rime_ice` to this schema.

Home Manager places the files; normal Rime redeployment compiles the
backend prism and reverse dictionary. There is no package installer or
startup-time configuration writer. Other dictionaries require an analogous
backend and mapping; `translator/packs` must match the source schema. A
missing mapping, Lua API, or gateway produces an explicit error.
Rime packs share the primary dictionary's syllabary and do not have their
own reverse databases; finding their entries requires reverse codes available
in the primary dictionary.

### Lookup and limits

The Lua bridge uses Rime's reverse lookup and built-in script translator
to find exact dictionary phrases and their normalized log weights. It
rejects automatic sentences and completion candidates. Emacs selects the
maximum-weight path; ties prefer fewer tokens, then the earlier longer
token. Unknown characters fall back to single characters with weight −30.
This does not use learned user phrases, the source schema's language model,
or simplification/emoji filters. Text variants absent from the raw dictionary
may therefore fall back to individual characters.

| Variable | Default | Description |
| --- | ---: | --- |
| `liberime-regexp-segment-max-word-length` | `8` | Maximum word length, in characters (1–64). |
| `liberime-regexp-segment-combination-limit` | `64` | Maximum reverse-code combinations per word (positive integer). |
| `liberime-regexp-segment-candidate-limit` | `128` | Maximum candidates examined per code (positive integer). |
| `liberime-regexp-segment-schema` | `"liberime_regexp_segment"` | Deployed gateway schema. |

These bounds can omit rare readings or lower-ranked dictionary entries.
Long runs are queried in overlapping 64-character chunks and segmented
globally. A separate reusable session preserves the input composition and
never commits or learns words. The result cache uses
`liberime-regexp-cache-size`; `liberime-regexp-clear-cache` and Rime restart
clear it. Redeploy through liberime when changing the Rime configuration
used by an already-running Emacs instance.

### Tests

`test/liberime-regexp-segment-test.el` covers the transport, weighted paths,
cache, Unicode offsets and editing behavior. `test/run-segment-integration.py`
accepts `--module` (the built liberime module), `--avy-directory`, and
optionally `--emacs`. It creates a temporary Rime home and tests real Lua
lookups, canonical codes under a double-pinyin schema, sentence rejection,
session recovery and input isolation, without touching the user's Rime data.

## Thanks

Thanks to [`rime-regexp.el`](https://github.com/colawithsauce/rime-regexp.el)
for the inspiration.
