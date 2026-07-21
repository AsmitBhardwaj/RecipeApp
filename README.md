# Recipe Extraction API — Backend MVP

Share an Instagram Reel / TikTok URL → get a structured recipe JSON back.
Synchronous MVP (no queue/worker): POST a URL, get the finished recipe in one
request/response cycle.

Pipeline (CLAUDE.md §5): `URL → canonical video id → cache check → yt-dlp
caption/metadata → signal check → LLM extraction (or dish-ID + generic
fallback) → schema validation (+1 retry) → image resolution → save`.

## Stack
- Python + FastAPI, SQLite (single file), yt-dlp, Anthropic API (Claude Sonnet).
- Image fallback: **Pexels** (`PEXELS_API_KEY`) — simplest free API (single-header auth).

## 1. Install
```bash
cd /Users/asmitbhardwaj/Documents/Recipe/RecipeApp
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

## 2. Configure secrets
```bash
cp .env.example .env
# then edit .env
```
Variables:
| Variable | Required | What it is |
|---|---|---|
| `ANTHROPIC_API_KEY` | **yes** | Your Anthropic key (LLM extraction). |
| `PEXELS_API_KEY` | no | Free key from https://www.pexels.com/api/ for stock-photo fallback. Omit → no image when a video has no thumbnail. |
| `ANTHROPIC_MODEL` | no | Defaults to `claude-sonnet-5`. |
| `DB_PATH` | no | Defaults to `recipes.db`. |
| `RATE_LIMIT_PER_MINUTE` | no | Defaults to `30`. |

`.env` is gitignored.

## 3. Run
```bash
source .venv/bin/activate
uvicorn app.main:app --reload --port 8000
```
Health check: `curl http://127.0.0.1:8000/`

## 4. Test with a real URL
```bash
curl -s -X POST http://127.0.0.1:8000/v1/jobs \
  -H "Content-Type: application/json" \
  -d '{"url":"https://www.tiktok.com/@yourchef/video/1234567890123456789"}' | python -m json.tool
```
Fetch a job later:
```bash
curl -s http://127.0.0.1:8000/v1/jobs/<job_id> | python -m json.tool
```

A successful response has `job.status == "complete"` and a populated `recipe`
(title, ingredients, instructions, confidence, `source_type`, `image_source`).
On failure `job.status == "failed"` with an `error_code` (e.g. `private_video`,
`login_required`, `could_not_identify_dish`).

> **Note on scraping:** TikTok public videos usually work with yt-dlp out of the
> box; Instagram increasingly requires login. If you hit `login_required`, that's
> the graceful failure path working — cookie support is deliberately out of MVP
> scope.
