# War Horn · Borderline

> A Go-inspired two-player turn-based strategy game. On a 19×19 board divided by the "Borderline", players battle through dynamic scoring mechanics such as territory, siege, and annihilation.

- Engine: Godot 4.7 (GDScript) / Web (TypeScript)
- Genre: Two-player turn-based strategy
- Duration: 30–60 minutes per game
- Platform: Windows desktop / Web browser

## Gameplay

### Match Flow: Deployment Phase → Formal Opening

Each match has two phases:

1. **Deployment Phase**: Both sides take turns placing 2 stones each (4 total) in **their own territory**. Each side has an **independent 2-minute countdown** (displayed on each score panel; a golden breathing light shows whose turn it is to deploy, and the bar turns red and breathes when under 30 seconds remain). Thinking time is paused during deployment.
2. **Formal Opening**: Begins automatically when deployment completes or the countdown runs out. A **circular expanding wave** animation (1.4 s) plays at the board center with an opening horn sound, then the thinking clock starts and players may move anywhere.

### Board & Forces

- 19×19 board; **row 10 is the Borderline** and belongs to neither side
- Rows 1–9 are Black's territory; rows 11–19 are White's territory
- Each side has **112 stones** (default; adjustable to 90 / 112 / 134 / 152 in the start menu), non-renewable

### Scoring Overview

```
Total = Occupation + Defense - Casualties
```

All scores are **computed live during play** — no endgame counting needed.

| Score Type | Components | Description |
|---|---|---|
| Occupation | Territory | Control in the opponent's territory |
| Defense | Annihilation + Siege | Defensive results in your own territory |
| Casualties | — | Cost of being captured |

### The Three Scoring Mechanics

1. **Territory**: Forming an enclosure in the opponent's territory or on the Borderline → +2 per enclosed point
2. **Annihilation**: Capturing opponent stones in your own territory or on the Borderline → +3/stone
3. **Siege**: Surrounding opponent stones that lack two eyes and sufficient space → +2/stone (live dynamic)

### Siege Rules

A stone group is considered **sieged** when all three conditions hold:
1. Surrounded by the opponent (purely geometric)
2. Has not formed two independent true eyes
3. Legal empty points inside the enclosure < 4

**Not sieged means alive** — there is no "dead stones" or "seki" concept.

### Pass & Endgame

- **Pass count**: each side is limited to **2 passes** per game (not allowed during deployment)
- **Pass cooldown**: after a side passes, it must complete 2 of its own turns (move/deploy/bounce) before it may pass again; a side that has never passed may pass anytime
- **Automatic endgame**: both sides pass consecutively → game ends, and the final score is settled (including ko resolution and final life-death judgment)
- **Forced endgame**: a side runs out of forces and both sides pass consecutively, or neither side can move → immediate end

## Special Systems

### Special Forces (optional rule)

Secretly deployed special stones, 2 uses per game:
- **Stealth**: invisible to the opponent; revealed when their timer expires or an adjacent enemy stone appears
- **Three endgame bonuses** (best one applies): territory involvement doubles / survival +3 / borderline contribution +50%
- **Bounce**: when the opponent collides with a hidden stone, it is randomly bounced to one of the 8 surrounding cells

### Komi System

- Default komi: **0.5 points**
- Adjustable in the start menu with `[−]` / `[+]` buttons in 0.5-point steps (0.0–20.5)

### Replay

Built-in classic game library, supports:
- Three categories: Classic / Master / Modern games
- SGF file import
- Step forward / backward / auto-play (0.5x–4x speed)
- Jump to any move

### AI Opponent

Five AI difficulties:
- Easy: heuristic AI
- Normal: shallow search AI
- Hard: standard search AI
- Expert: search + MCTS on key positions
- Master: deeper search + more simulations

### Online Battle

LAN multiplayer based on Godot's ENet, with host/client modes (desktop); real-time matchmaking, rooms and ranked battles over Socket.IO (web). The host sets thinking time / forces / komi and starts a room.

### Language Support

Chinese and English are both supported. Click the language button on the main menu to switch; your preference is saved automatically.

## Game Modes

| Mode | Description |
|---|---|
| Local 2-Player | Play on the same screen |
| vs AI | Five AI difficulties |
| Online Battle | Host or join |
| Replay | Study classic games |
| Tsumego | Life-and-death puzzle challenges (30 levels) |

## Starting a Game

1. On the main menu choose a mode (Local 2-Player / vs AI / Online / Replay / Tsumego / Tutorial).
2. Set match options:
   - **Thinking time**: Amateur (Unlimited / Blitz 5m / Rapid 15m+30s×3 / Standard 30m+30s×3 / Amateur 60m+30s×5) and Professional (Pro Rapid 1h+30s×5 / Pro Normal 3h+60s×5 / Pro Grand 5h+60s×5 / Title Match 8h+60s×10); default is Unlimited
   - **Komi**: default 0.5, `[−]` / `[+]` steps of 0.5 (0.0–20.5)
   - **Forces**: 90 / 112 / 134 / 152, default 112
3. Click Start to enter the **deployment phase** (see "Match Flow"); when deployment completes the **formal opening** begins automatically.
4. Online battle: the host sets the above options in the room and clicks "Start Game"; the config is pushed to the client and both sides start simultaneously.

## Web Version (`web/`)

The browser version lives under `web/`:

- **Stack**: Vite + TypeScript (frontend), Express + Socket.IO (backend)
- **Features**: human-vs-AI, real-time online battles, tsumego challenges, war fog, byo-yomi timers, multiplayer themes
- **Run locally**:

```bash
cd web
npm install
npm run dev:server   # backend on :3000
npm run dev:client   # frontend on :5173
```

- **Build** (production):

```bash
cd web
npm install
npm run build
```

- **Deploy**: single-service build. The backend serves the built frontend from `packages/client/dist` (see `web/railway.json` for Railway deployment).

## Tech Stack

- **Desktop (Godot)**: Godot 4.7 (GDScript), gl_compatibility renderer, ENet Multiplayer API, RefCounted pure logic layer + Control UI layer
- **Web**: Vite + TypeScript, Express + Socket.IO, Node.js ≥ 18

## Repository

- Gitee: https://gitee.com/shamdom888/warhorn-borderline
- GitHub: https://github.com/longgege-cd/GoVariant-WarHorn