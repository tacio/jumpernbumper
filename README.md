# Jumper 'n Bumper

An online multiplayer arena platformer for up to 4 players, inspired by **Jump 'n Bump**.
Jump on your rivals' heads to score, avoid getting stomped yourself, and be the first bunny to reach the kill target. You can also play against robot bunnies controlled by the server.

- [Install](#install)
- [Connect to a server](#connect-to-a-server)
- [Play a match](#play-a-match)
- [How to play](#how-to-play)
- [Controls](#controls)
- [Troubleshooting](#troubleshooting)
- [Host a server for your friends](#host-a-server-for-your-friends)
- [For developers](#for-developers)

---

## Install

Download the file for your system from the **[latest release](https://github.com/tacio/jumpernbumper/releases/latest)**:

| System | File |
| --- | --- |
| Windows 10/11 (64-bit) | `jumpernbumper-windows-x86_64.zip` |
| macOS (Intel and Apple Silicon) | `jumpernbumper-macos-universal.zip` |
| Linux (x86_64) | `jumpernbumper-linux-x86_64.tar.gz` |

No installer is needed: the game is a single file you unpack and run.

### Windows

1. Right-click the `.zip` → **Extract All…**
2. Double-click `jumpernbumper.exe`.
3. If Windows shows **"Windows protected your PC"**, click **More info → Run anyway**. The game isn't code-signed, so Windows warns about it.

### macOS

1. Double-click the `.zip` to unpack it, then drag **Jumper 'n Bumper.app** into **Applications**.
2. The first time, **right-click (or Control-click) the app → Open → Open**. The app isn't signed by Apple, so a normal double-click is blocked the first time.
3. If macOS says the app **"is damaged and can't be opened"**, run this once in Terminal, then open the app again:
   ```bash
   xattr -dr com.apple.quarantine "/Applications/Jumper 'n Bumper.app"
   ```

### Linux

```bash
tar xzf jumpernbumper-linux-x86_64.tar.gz
chmod +x jumpernbumper.x86_64
./jumpernbumper.x86_64
```

The game uses OpenGL 3.3 (Godot's Compatibility renderer), so up-to-date graphics drivers are enough.

---

## Connect to a server

There's no built-in public server. Everyone in a game connects to **the same server**, which one of you runs (see [Host a server](#host-a-server-for-your-friends)), and that person gives the others its address.

On the title screen:

1. **NICKNAME**: type a name (1–16 characters).
2. **SERVER WS**: paste the server address. It looks like one of these:
   - `ws://192.168.1.20:3000/v1/database/jumpernbumper/subscribe` (a server on your home network)
   - `wss://maincloud.spacetimedb.com/v1/database/<database-name>/subscribe` (a server hosted on SpacetimeDB Maincloud)
   - The default `ws://127.0.0.1:3000/...` only works when the server runs on your own computer.
3. Click **CONNECT**.

The game doesn't remember the address yet, so keep it somewhere you can paste it from.

---

## Play a match

### 1. Find or create a room

After connecting you'll see the room browser:

- **Join a public room**: pick a room under **PUBLIC WAITING ROOMS** and click **JOIN**. It shows how many players are in each room (`2/4`).
- **Join a friend's private room**: type their 5-letter code (for example `K7QXM`) next to **JOIN CODE** and click **JOIN**. Upper or lower case both work.
- **Create your own room**: type a name next to **NEW ROOM**, tick **Public** if anyone should be able to find it in the list, and click **CREATE**. You become the room's **host**.

Private rooms don't show up in the list, and their code is only visible to players inside the room. Click **COPY** in the lobby to copy the code and send it to your friends.

### 2. In the lobby

- **Pick a bunny**: each of the 4 slots is a different bunny (**Dott, Jiffy, Fizz, Mijji**). Click **PICK** on a free slot to switch.
- **READY UP**: every player has to be ready before the match can start.
- **The host also controls:**
  - **Win condition**: **KILLS** (first to 5 / 10 / 20, or any number from 1 to 99 with − / +) or **TIME** (60 / 120 / 180 s, anywhere from 10 s to 10 min; the most kills when time runs out wins).
  - **Mods**: **Low Grav** (floaty jumps), **Pogo** (bunnies bounce automatically), **Jetpack** (hold jump to fly), **Gore** (turn off for a puff of smoke instead of a splat).
  - **+ BOT / KICK BOT**: fill empty slots with robot bunnies.
  - **START MATCH**: enabled once everyone is ready.

If the host leaves, another human player becomes host. Matches already in progress can't be joined.

### 3. After the match

The podium screen shows the winner, or **MATCH DRAW** if the top players are tied. The host can click **RETURN TO LOBBY** for a rematch; anyone can **LEAVE ROOM**.

---

## How to play

- **Stomp to score**: land on another bunny's head to squash them and score a kill. You bounce off them afterwards, so you can chain stomps.
- **Watch your head**: jumping up into a bunny from underneath gets *you* squashed.
- **Bumping sideways is safe**: bunnies at the same height just push each other apart.
- **Respawn**: squashed bunnies come back after about 1.5 seconds at the spawn point farthest from other players, and blink for half a second while they can't be hurt or hurt anyone.
- **The meadow**:
  - **Water**: you sink slowly; tap or hold jump to swim up.
  - **Ice**: slippery, so you slide before stopping or turning.
  - **Springs**: launch you high into the air.
- **Winning**: in Kills mode, the first bunny to reach the target wins. In Time mode, the most kills when the clock runs out wins, and a tie is a draw. If everyone else leaves mid-match, the last player wins.

---

## Controls

| Action | Keyboard | Gamepad |
| --- | --- | --- |
| Move left | `A` / `←` | D-pad left / left stick |
| Move right | `D` / `→` | D-pad right / left stick |
| Jump / swim / jetpack | `W` / `↑` / `Space` | `A` (Xbox) / `✕` (PlayStation) |
| Match menu (resume, leave room, disconnect) | `Esc` | `Start` |

To change them, click **CONTROLS** on the title screen, click a slot, then press the new key or button (`Esc` cancels). **RESET DEFAULTS** restores the table above. Your bindings are saved on your computer. Menus work with the D-pad or left stick too.

---

## Troubleshooting

| Problem | What to try |
| --- | --- |
| **"Connection timed out"** or **"Unable to connect"** | Check the address: it must start with `ws://` or `wss://` and end with `/subscribe`. Make sure the server is running. On a home network, the host's firewall must allow port 3000. |
| **"Server URL must start with ws:// or wss://"** | You pasted an `http://` address. Replace `http` with `ws` (or `https` with `wss`). |
| **Connected, but the screens stay empty** or rooms never appear | Your game and the server are different versions. Download the latest release, and ask the host to update the server. |
| **"Room … not found"** | The code is wrong, or everyone left and the room closed. |
| **"Room is locked"** | That room's match already started. Wait for it to finish or join another room. |
| **"Room is full"** | All 4 slots are taken (bots count too). |
| **Dropped out of a match** | A disconnect removes you from the room. Reconnect and rejoin when the match is over. |

---

## Host a server for your friends

The server is a [SpacetimeDB](https://spacetimedb.com/) module. You need this repository plus:

- [Rust](https://rustup.rs/) with the WebAssembly target: `rustup target add wasm32-unknown-unknown`
- The [SpacetimeDB CLI](https://spacetimedb.com/install) (version 2.16)
- [just](https://github.com/casey/just) (optional; it runs the shortcut commands below)

```bash
git clone https://github.com/tacio/jumpernbumper.git
cd jumpernbumper
```

### Option A: on your computer, for your home network

```bash
STDB_LISTEN_ADDR=0.0.0.0:3000 just server
```

Leave it running (`Ctrl+C` stops it). Then:

- **You** connect with `ws://127.0.0.1:3000/v1/database/jumpernbumper/subscribe`.
- **Friends on the same network** use your computer's local IP address (find it with `ipconfig` on Windows, `ipconfig getifaddr en0` on macOS, or `hostname -I` on Linux): `ws://<your-ip>:3000/v1/database/jumpernbumper/subscribe`.
- If friends can't connect, allow incoming TCP connections on port **3000** in your firewall.

Friends outside your network would need a port forward on your router. For that case, Option B is easier.

### Option B: on SpacetimeDB Maincloud, reachable from anywhere

```bash
spacetime login
spacetime publish <database-name> --server maincloud --module-path server/spacetimedb
```

Database names on Maincloud are shared by everyone, so pick one that's unlikely to be taken (for example `jumpernbumper-yourname`). Players then connect with:

```
wss://maincloud.spacetimedb.com/v1/database/<database-name>/subscribe
```

### Updating the server

Pull the latest code and publish again: `just server` for Option A, the same `spacetime publish` command for Option B. Players connected at the time are disconnected and need the **matching game release**. Rooms and matches don't survive server updates anyway, so if a publish refuses with "requires manual migration", it's safe to add `--delete-data`.

---

## For developers

The game is built with **Godot 4.7.2** (GDScript client) and **SpacetimeDB 2.16** (Rust server module, with 30 Hz physics running on the server). See **[docs/DEVELOPMENT.md](docs/DEVELOPMENT.md)** for setup, commands, tests, how the code is organised, and how releases are made.
