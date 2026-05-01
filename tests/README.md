# SU plugin unit tests

Run before each release to catch logic bugs without involving SketchUp.

## Run

```bash
./tests/run.sh                  # via Docker (no Ruby needed on host)
# or
ruby tests/test_su_gpt_render.rb   # if you have ruby 3+ locally
```

Output:
```
32 runs, 86 assertions, 0 failures, 0 errors, 0 skips
```

## What it covers

| Area | Tests |
|---|---|
| `version_newer?` edge cases | 5 (basic, major bump, short form `0.2`, double digit `0.10`, equality) |
| Poe response URL regex | 5 (Poe CDN no-extension, .png, Chinese alt text, bare URL fallback, no URL) |
| Config save/load | 3 (empty, roundtrip, invalid JSON) |
| Update logic | 3 (newer / same / 404) |
| Hot-reload (`load __FILE__`) | 2 (method redefine, constant redefine) |
| Tray HTML render | 4 (basic, model dropdown, missing/present API key) |
| History HTML | 3 (empty, with entries, count) |
| `call_poe` payload + parsing | 3 (success, no URL → raise, HTTP error → raise) |
| Image-model list invariants | 4 (no T2I leak, default = GPT-Image-2, includes Nano-Banana Pro, excludes Nano-Banana 2 / DALL-E 3 / Imagen) |

## What it does NOT cover

- HtmlDialog `add_action_callback` actual late-binding under SketchUp's Ruby
- Poe API real response variants (we use the canonical markdown image response)
- Wine / Windows-specific runtime behaviour
- SU `UI.start_timer` from background thread quirks (the v0.2.5 silent-update bug was here)
- Net::HTTP TLS handshake against real Cloudflare (verified via curl, not test rig)

## Files

- `sketchup_stub.rb` — minimal stub for `Sketchup`, `UI`, `UI::HtmlDialog`,
  `file_loaded?`, satisfies `require 'sketchup.rb'` / `require 'extensions.rb'`
- `test_su_gpt_render.rb` — Minitest test classes
- `run.sh` — Docker wrapper

## Pattern: stubbing HTTP

We override `SuGptRender.http_get` and `SuGptRender.http_post_json` to return
canned `FakeHttpResponse` objects. This isolates the plugin's logic from
network and tests the higher-level flow (regex parsing, retry loop accounting,
URL handling) without hitting Poe or GitHub.

Each test sets `SuGptRender.stub_responses` to a hash mapping URL → response
(or `"*"` → response for any URL). `SuGptRender.stub_calls` records what was
called, for assertions like "we sent a POST with the right model + image".

## Adding a new test

1. Open `test_su_gpt_render.rb`
2. Pick or add a `class TestX < Minitest::Test`
3. Write a `def test_y` that exercises the behaviour
4. Use `assert`, `assert_equal`, `assert_raises`, `refute`, `assert_includes`
5. `./tests/run.sh` to verify

## CI integration (future)

Could wire to GitHub Actions:

```yaml
on: [push, pull_request]
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: ruby/setup-ruby@v1
        with: { ruby-version: 3.2 }
      - run: ruby tests/test_su_gpt_render.rb
```

Then before every plugin release, CI must pass.
