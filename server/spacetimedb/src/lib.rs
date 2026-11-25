//! Authoritative SpacetimeDB v2.16.3 multiplayer backend for Jumper 'n Bumper.
//!
//! Public tables use flat schemas without `Option` fields so `v1.json.spacetimedb`
//! array/object decoding in GDScript (`SpacetimeWire.gd`) is simple and unambiguous.
//!
//! ## Public Table Column Order (for `TransactionUpdate` positional array decoding)
//! 1. `player`: `["identity", "nickname", "connected", "room_id"]`
//! 2. `room`: `["id", "code", "name", "is_public", "host_identity", "status", "win_mode", "win_target", "mut_low_gravity", "mut_pogo", "mut_jetpack", "gore_enabled", "tick_count", "elapsed_ms", "winner_slot"]`
//! 3. `room_member`: `["identity", "room_id", "slot", "nickname", "ready", "kills", "deaths", "is_bot"]`
//! 4. `match_bunny`: `["identity", "room_id", "slot", "x", "y", "vx", "vy", "facing", "alive", "respawn_ticks", "invuln_ticks", "on_ground", "in_water", "on_ice", "prev_jump", "input_bits", "last_seq", "is_bot"]`
//! 5. `kill_event`: `["id", "room_id", "tick", "killer_slot", "victim_slot", "x", "y"]`
//!
//! ## Status & Enum Constants
//! - `Room.status`: `0 = Waiting`, `1 = InProgress`, `2 = Finished`
//! - `Room.win_mode`: `0 = Kills`, `1 = Time`
//! - `Room.winner_slot`: `-1 = none/draw`, `0..=3 = winning bunny slot`
//! - `Player.room_id`: `0 = none`, `>= 1 = active room id`
//! - `MatchBunny.input_bits`: `1 = Left`, `2 = Right`, `4 = Jump`

use spacetimedb::rand::Rng;
use spacetimedb::{Identity, ReducerContext, ScheduleAt, Table, TimeDuration};

/// Tick interval in milliseconds (~30 Hz).
const TICK_INTERVAL_MS: u64 = 33;

/// Maximum number of players allowed per room (4 classic bunny slots).
const MAX_ROOM_PLAYERS: usize = 4;

/// Room lifecycle states (`Room.status`).
pub const STATUS_WAITING: u8 = 0;
pub const STATUS_IN_PROGRESS: u8 = 1;
pub const STATUS_FINISHED: u8 = 2;

/// Match win condition modes (`Room.win_mode`).
pub const WIN_MODE_KILLS: u8 = 0;
pub const WIN_MODE_TIME: u8 = 1;

const DEFAULT_WIN_KILLS: u32 = 10;
const MIN_KILL_TARGET: u32 = 1;
const MAX_KILL_TARGET: u32 = 99;
const MIN_TIME_TARGET_SECS: u32 = 10;
const MAX_TIME_TARGET_SECS: u32 = 600;

const MIN_NICKNAME_LEN: usize = 1;
const MAX_NICKNAME_LEN: usize = 16;
const MIN_ROOM_NAME_LEN: usize = 1;
const MAX_ROOM_NAME_LEN: usize = 32;
const ROOM_CODE_LEN: usize = 5;

/// Unambiguous uppercase alphanumeric alphabet for 5-character room codes.
const CODE_ALPHABET: &[u8] = b"ABCDEFGHJKLMNPQRSTUVWXYZ23456789";

/// Connected/known player profile and active room membership pointer (`0` = none).
#[spacetimedb::table(accessor = player, public)]
#[derive(Clone, Debug)]
pub struct Player {
    #[primary_key]
    pub identity: Identity,
    pub nickname: String,
    pub connected: bool,
    pub room_id: u64,
}

/// Lobby and match state for a game room (`id >= 1`; `0` is reserved as sentinel "no room").
#[spacetimedb::table(accessor = room, public)]
#[derive(Clone, Debug)]
pub struct Room {
    #[primary_key]
    #[auto_inc]
    pub id: u64,
    #[unique]
    pub code: String,
    pub name: String,
    pub is_public: bool,
    pub host_identity: Identity,
    #[index(btree)]
    pub status: u8,
    pub win_mode: u8,
    pub win_target: u32,
    pub mut_low_gravity: bool,
    pub mut_pogo: bool,
    pub mut_jetpack: bool,
    pub gore_enabled: bool,
    pub tick_count: u64,
    pub elapsed_ms: u32,
    pub winner_slot: i8,
}

/// Player membership, selected bunny slot (`0..=3`), ready state, and match scoreboard.
#[spacetimedb::table(accessor = room_member, public)]
#[derive(Clone, Debug)]
pub struct RoomMember {
    #[primary_key]
    pub identity: Identity,
    #[index(btree)]
    pub room_id: u64,
    pub slot: u8,
    pub nickname: String,
    pub ready: bool,
    pub kills: u32,
    pub deaths: u32,
    pub is_bot: bool,
}

/// Authoritative physics state for an active bunny in an `InProgress` room.
#[spacetimedb::table(accessor = match_bunny, public)]
#[derive(Clone, Debug)]
pub struct MatchBunny {
    #[primary_key]
    pub identity: Identity,
    #[index(btree)]
    pub room_id: u64,
    pub slot: u8,
    pub x: f32,
    pub y: f32,
    pub vx: f32,
    pub vy: f32,
    pub facing: i8,
    pub alive: bool,
    pub respawn_ticks: u16,
    pub invuln_ticks: u16,
    pub on_ground: bool,
    pub in_water: bool,
    pub on_ice: bool,
    pub prev_jump: bool,
    pub input_bits: u8,
    pub last_seq: u32,
    pub is_bot: bool,
}

/// Discrete stomp kill event emitted during `match_tick` for kill feed and VFX/SFX.
#[spacetimedb::table(accessor = kill_event, public)]
#[derive(Clone, Debug)]
pub struct KillEvent {
    #[primary_key]
    #[auto_inc]
    pub id: u64,
    #[index(btree)]
    pub room_id: u64,
    pub tick: u64,
    pub killer_slot: u8,
    pub victim_slot: u8,
    pub x: f32,
    pub y: f32,
}

/// Repeating 33 ms (~30 Hz) schedule driving `match_tick` while any room is `InProgress`.
#[spacetimedb::table(accessor = match_tick_schedule, scheduled(match_tick))]
pub struct MatchTickSchedule {
    #[primary_key]
    #[auto_inc]
    pub scheduled_id: u64,
    pub scheduled_at: ScheduleAt,
}

/// Module initialization hook.
#[spacetimedb::reducer(init)]
pub fn init(_ctx: &ReducerContext) {
    log::info!(
        "jumpernbumper module initialized (sim tick_rate_hz={})",
        sim::tick_rate_hz()
    );
}

/// Registers or reconnects a `Player` record when a WebSocket client connects.
#[spacetimedb::reducer(client_connected)]
pub fn client_connected(ctx: &ReducerContext) {
    let caller = ctx.sender();
    if let Some(mut player) = ctx.db.player().identity().find(caller) {
        player.connected = true;
        if player.room_id != 0 && ctx.db.room().id().find(player.room_id).is_none() {
            player.room_id = 0;
        }
        ctx.db.player().identity().update(player);
    } else {
        ctx.db.player().insert(Player {
            identity: caller,
            nickname: default_nickname(caller),
            connected: true,
            room_id: 0,
        });
    }
}

/// Cleans up room membership and marks the `Player` disconnected when a client drops.
#[spacetimedb::reducer(client_disconnected)]
pub fn client_disconnected(ctx: &ReducerContext) {
    let caller = ctx.sender();
    remove_player_from_room(ctx, caller);
    if let Some(mut player) = ctx.db.player().identity().find(caller) {
        player.connected = false;
        player.room_id = 0;
        ctx.db.player().identity().update(player);
    }
}

/// Sets the caller's trimmed nickname (`1..=16` chars) on both `Player` and `RoomMember`.
#[spacetimedb::reducer]
pub fn set_nickname(ctx: &ReducerContext, nickname: String) -> Result<(), String> {
    let trimmed = nickname.trim();
    let len = trimmed.chars().count();
    if !(MIN_NICKNAME_LEN..=MAX_NICKNAME_LEN).contains(&len) {
        return Err(format!(
            "Nickname must be between {MIN_NICKNAME_LEN} and {MAX_NICKNAME_LEN} characters"
        ));
    }

    let caller = ctx.sender();
    let mut player = ensure_player(ctx, caller);
    player.nickname = trimmed.to_string();
    ctx.db.player().identity().update(player);

    if let Some(mut member) = ctx.db.room_member().identity().find(caller) {
        member.nickname = trimmed.to_string();
        ctx.db.room_member().identity().update(member);
    }
    Ok(())
}

/// Creates a new room with a unique 5-char uppercase code, auto-leaving any existing room.
#[spacetimedb::reducer]
pub fn create_room(ctx: &ReducerContext, name: String, is_public: bool) -> Result<(), String> {
    let trimmed = name.trim();
    let len = trimmed.chars().count();
    if !(MIN_ROOM_NAME_LEN..=MAX_ROOM_NAME_LEN).contains(&len) {
        return Err(format!(
            "Room name must be between {MIN_ROOM_NAME_LEN} and {MAX_ROOM_NAME_LEN} characters"
        ));
    }

    let caller = ctx.sender();
    remove_player_from_room(ctx, caller);
    let mut player = ensure_player(ctx, caller);
    let code = generate_unique_room_code(ctx)?;

    let mut room = ctx.db.room().insert(Room {
        id: 0,
        code,
        name: trimmed.to_string(),
        is_public,
        host_identity: caller,
        status: STATUS_WAITING,
        win_mode: WIN_MODE_KILLS,
        win_target: DEFAULT_WIN_KILLS,
        mut_low_gravity: false,
        mut_pogo: false,
        mut_jetpack: false,
        gore_enabled: true,
        tick_count: 0,
        elapsed_ms: 0,
        winner_slot: -1,
    });
    // Guarantee `room.id >= 1` so `0` remains strictly sentinel "no room".
    if room.id == 0 {
        ctx.db.room().id().delete(0);
        room = ctx.db.room().insert(Room { id: 0, ..room });
    }

    player.room_id = room.id;
    let nickname = player.nickname.clone();
    ctx.db.player().identity().update(player);

    ctx.db.room_member().insert(RoomMember {
        identity: caller,
        room_id: room.id,
        slot: 0,
        nickname,
        ready: true,
        kills: 0,
        deaths: 0,
        is_bot: false,
    });

    Ok(())
}

/// Joins a `Waiting` room by its 5-character case-insensitive room code.
#[spacetimedb::reducer]
pub fn join_room_by_code(ctx: &ReducerContext, code: String) -> Result<(), String> {
    let normalized = code.trim().to_ascii_uppercase();
    if normalized.len() != ROOM_CODE_LEN {
        return Err("Room code must be 5 characters".to_string());
    }
    let room = ctx
        .db
        .room()
        .code()
        .find(&normalized)
        .ok_or_else(|| format!("Room '{normalized}' not found"))?;
    join_room_internal(ctx, room)
}

/// Joins a `Waiting` public room by `room_id`.
#[spacetimedb::reducer]
pub fn join_public_room(ctx: &ReducerContext, room_id: u64) -> Result<(), String> {
    if room_id == 0 {
        return Err("Invalid room_id".to_string());
    }
    let room = ctx
        .db
        .room()
        .id()
        .find(room_id)
        .ok_or_else(|| "Room not found".to_string())?;
    if !room.is_public {
        return Err("Room is private; join with its room code".to_string());
    }
    join_room_internal(ctx, room)
}

/// Leaves the caller's current room, migrating host or deleting empty rooms.
#[spacetimedb::reducer]
pub fn leave_room(ctx: &ReducerContext) -> Result<(), String> {
    remove_player_from_room(ctx, ctx.sender());
    Ok(())
}

/// Changes the caller's bunny slot (`0..=3`) while in a `Waiting` room if the slot is free.
#[spacetimedb::reducer]
pub fn select_bunny_slot(ctx: &ReducerContext, slot: u8) -> Result<(), String> {
    if slot >= MAX_ROOM_PLAYERS as u8 {
        return Err("Bunny slot must be between 0 and 3".to_string());
    }
    let caller = ctx.sender();
    let (room, mut member) = require_caller_room_and_member(ctx, caller)?;
    if room.status != STATUS_WAITING {
        return Err("Cannot change bunny slot after match has started".to_string());
    }
    if member.slot == slot {
        return Ok(());
    }
    let slot_taken = ctx
        .db
        .room_member()
        .room_id()
        .filter(&room.id)
        .any(|m| m.slot == slot);
    if slot_taken {
        return Err(format!("Bunny slot {slot} is already taken"));
    }

    member.slot = slot;
    ctx.db.room_member().identity().update(member);
    Ok(())
}

/// Toggles the caller's ready flag while in a `Waiting` room.
#[spacetimedb::reducer]
pub fn toggle_ready(ctx: &ReducerContext) -> Result<(), String> {
    let caller = ctx.sender();
    let (room, mut member) = require_caller_room_and_member(ctx, caller)?;
    if room.status != STATUS_WAITING {
        return Err("Cannot toggle ready outside lobby".to_string());
    }
    member.ready = !member.ready;
    ctx.db.room_member().identity().update(member);
    Ok(())
}

/// Adds a server-controlled robot bunny into an open `slot` (`0..=3`) (host only, `Waiting` room only).
#[spacetimedb::reducer]
pub fn add_bot(ctx: &ReducerContext, slot: u8) -> Result<(), String> {
    if slot >= MAX_ROOM_PLAYERS as u8 {
        return Err("Bunny slot must be between 0 and 3".to_string());
    }
    let caller = ctx.sender();
    let (room, _member) = require_caller_room_and_member(ctx, caller)?;
    if room.host_identity != caller {
        return Err("Only the room host can add bots".to_string());
    }
    if room.status != STATUS_WAITING {
        return Err("Cannot add bots after match has started".to_string());
    }

    let members: Vec<RoomMember> = ctx
        .db
        .room_member()
        .room_id()
        .filter(&room.id)
        .collect();
    if members.len() >= MAX_ROOM_PLAYERS {
        return Err("Room is full (max 4 players)".to_string());
    }
    if members.iter().any(|m| m.slot == slot) {
        return Err(format!("Bunny slot {slot} is already taken"));
    }

    let bot_id = bot_identity(room.id, slot);
    ctx.db.room_member().insert(RoomMember {
        identity: bot_id,
        room_id: room.id,
        slot,
        nickname: bot_name_for_slot(slot),
        ready: true,
        kills: 0,
        deaths: 0,
        is_bot: true,
    });
    Ok(())
}

/// Removes a robot bunny from `slot` (`0..=3`) (host only, `Waiting` room only).
#[spacetimedb::reducer]
pub fn remove_bot(ctx: &ReducerContext, slot: u8) -> Result<(), String> {
    if slot >= MAX_ROOM_PLAYERS as u8 {
        return Err("Bunny slot must be between 0 and 3".to_string());
    }
    let caller = ctx.sender();
    let (room, _member) = require_caller_room_and_member(ctx, caller)?;
    if room.host_identity != caller {
        return Err("Only the room host can remove bots".to_string());
    }
    if room.status != STATUS_WAITING {
        return Err("Cannot remove bots after match has started".to_string());
    }

    let bot_member = ctx
        .db
        .room_member()
        .room_id()
        .filter(&room.id)
        .find(|m| m.slot == slot && m.is_bot)
        .ok_or_else(|| format!("No bot in slot {slot}"))?;

    ctx.db.room_member().identity().delete(bot_member.identity);
    Ok(())
}

/// Updates match rules and mutators (host only, `Waiting` room only).
#[spacetimedb::reducer]
pub fn update_room_settings(
    ctx: &ReducerContext,
    win_mode: u8,
    win_target: u32,
    mut_low_gravity: bool,
    mut_pogo: bool,
    mut_jetpack: bool,
    gore_enabled: bool,
) -> Result<(), String> {
    let caller = ctx.sender();
    let (mut room, _member) = require_caller_room_and_member(ctx, caller)?;
    if room.host_identity != caller {
        return Err("Only the room host can update room settings".to_string());
    }
    if room.status != STATUS_WAITING {
        return Err("Cannot update settings unless room is Waiting".to_string());
    }

    match win_mode {
        WIN_MODE_KILLS => {
            if !(MIN_KILL_TARGET..=MAX_KILL_TARGET).contains(&win_target) {
                return Err(format!(
                    "Kill target must be between {MIN_KILL_TARGET} and {MAX_KILL_TARGET}"
                ));
            }
        }
        WIN_MODE_TIME => {
            if !(MIN_TIME_TARGET_SECS..=MAX_TIME_TARGET_SECS).contains(&win_target) {
                return Err(format!(
                    "Time target must be between {MIN_TIME_TARGET_SECS} and {MAX_TIME_TARGET_SECS} seconds"
                ));
            }
        }
        _ => return Err("Invalid win_mode (expected 0=Kills or 1=Time)".to_string()),
    }

    room.win_mode = win_mode;
    room.win_target = win_target;
    room.mut_low_gravity = mut_low_gravity;
    room.mut_pogo = mut_pogo;
    room.mut_jetpack = mut_jetpack;
    room.gore_enabled = gore_enabled;
    ctx.db.room().id().update(room);
    Ok(())
}

/// Starts the match for a `Waiting` room once all members are ready (host only).
#[spacetimedb::reducer]
pub fn start_match(ctx: &ReducerContext) -> Result<(), String> {
    let caller = ctx.sender();
    let (mut room, _member) = require_caller_room_and_member(ctx, caller)?;
    if room.host_identity != caller {
        return Err("Only the room host can start the match".to_string());
    }
    if room.status != STATUS_WAITING {
        return Err("Match can only be started from Waiting status".to_string());
    }

    let mut members: Vec<RoomMember> = ctx
        .db
        .room_member()
        .room_id()
        .filter(&room.id)
        .collect();
    if members.is_empty() {
        return Err("Cannot start an empty room".to_string());
    }
    if members.iter().any(|m| !m.ready) {
        return Err("All players must be ready before starting".to_string());
    }
    members.sort_by_key(|m| m.slot);

    clear_room_match_entities(ctx, room.id);

    let arena = sim::Arena::classic_meadow();
    let constants = sim::PhysicsConstants::default_shared();

    for mut member in members {
        member.kills = 0;
        member.deaths = 0;
        let slot = member.slot;
        let identity = member.identity;
        let is_bot = member.is_bot;
        ctx.db.room_member().identity().update(member);

        let [sx, sy] = arena.spawn_points[slot as usize % arena.spawn_points.len()];
        ctx.db.match_bunny().insert(MatchBunny {
            identity,
            room_id: room.id,
            slot,
            x: sx,
            y: sy,
            vx: 0.0,
            vy: 0.0,
            facing: 1,
            alive: true,
            respawn_ticks: 0,
            invuln_ticks: constants.spawn_invuln_ticks,
            on_ground: false,
            in_water: false,
            on_ice: false,
            prev_jump: false,
            input_bits: 0,
            last_seq: 0,
            is_bot,
        });
    }

    room.status = STATUS_IN_PROGRESS;
    room.tick_count = 0;
    room.elapsed_ms = 0;
    room.winner_slot = -1;
    ctx.db.room().id().update(room);

    ensure_match_schedule_running(ctx);
    Ok(())
}

/// Updates the caller's `MatchBunny` input bitmask and sequence number during an `InProgress` match.
#[spacetimedb::reducer]
pub fn send_input(ctx: &ReducerContext, input_bits: u8, seq: u32) -> Result<(), String> {
    let caller = ctx.sender();
    let mut bunny = ctx
        .db
        .match_bunny()
        .identity()
        .find(caller)
        .ok_or_else(|| "Caller does not have an active match bunny".to_string())?;
    let room = ctx
        .db
        .room()
        .id()
        .find(bunny.room_id)
        .ok_or_else(|| "Room not found".to_string())?;
    if room.status != STATUS_IN_PROGRESS {
        return Err("Match is not in progress".to_string());
    }

    if seq >= bunny.last_seq {
        let valid_mask = sim::InputBits::LEFT | sim::InputBits::RIGHT | sim::InputBits::JUMP;
        bunny.input_bits = input_bits & valid_mask;
        bunny.last_seq = seq;
        ctx.db.match_bunny().identity().update(bunny);
    }
    Ok(())
}

/// Scheduled 30 Hz (33 ms) reducer stepping all `InProgress` rooms via `sim::step_room`.
#[spacetimedb::reducer]
pub fn match_tick(ctx: &ReducerContext, _schedule: MatchTickSchedule) {
    if ctx.sender() != ctx.database_identity() {
        log::warn!("Ignoring unauthorized direct call to match_tick");
        return;
    }

    let in_progress_rooms: Vec<Room> = ctx
        .db
        .room()
        .status()
        .filter(&STATUS_IN_PROGRESS)
        .collect();
    if in_progress_rooms.is_empty() {
        stop_match_schedule(ctx);
        return;
    }

    let arena = sim::Arena::classic_meadow();
    let constants = sim::PhysicsConstants::default_shared();
    let hz = u64::from(constants.tick_rate_hz.max(1));

    for mut room in in_progress_rooms {
        let mut bunny_rows: Vec<MatchBunny> = ctx
            .db
            .match_bunny()
            .room_id()
            .filter(&room.id)
            .collect();
        if bunny_rows.is_empty() {
            room.status = STATUS_FINISHED;
            room.winner_slot = -1;
            ctx.db.room().id().update(room);
            continue;
        }
        bunny_rows.sort_by_key(|b| b.slot);

        let mut sim_states: Vec<sim::BunnyState> =
            bunny_rows.iter().map(match_bunny_to_sim).collect();
        let mutators = sim::Mutators {
            low_gravity: room.mut_low_gravity,
            pogo: room.mut_pogo,
            jetpack: room.mut_jetpack,
        };

        let snapshot = sim_states.clone();
        for (idx, row) in bunny_rows.iter().enumerate() {
            if row.is_bot {
                sim_states[idx].input_bits =
                    sim::compute_bot_input(&snapshot[idx], &snapshot, &arena, &constants, &mutators);
            }
        }

        let next_tick = room.tick_count + 1;
        let next_elapsed_ms = ((next_tick * 1000) / hz) as u32;
        let events = sim::step_room(&mut sim_states, &arena, &constants, &mutators, next_tick);

        for (row, state) in bunny_rows.into_iter().zip(sim_states.iter()) {
            if bunny_state_differs(&row, state) {
                let mut updated = row;
                apply_sim_to_match_bunny(&mut updated, state);
                ctx.db.match_bunny().identity().update(updated);
            }
        }

        let mut members: Vec<RoomMember> = ctx
            .db
            .room_member()
            .room_id()
            .filter(&room.id)
            .collect();
        let mut members_dirty = false;

        for event in events {
            if let sim::StepEvent::Killed {
                killer_slot,
                victim_slot,
                x,
                y,
            } = event
            {
                ctx.db.kill_event().insert(KillEvent {
                    id: 0,
                    room_id: room.id,
                    tick: next_tick,
                    killer_slot,
                    victim_slot,
                    x,
                    y,
                });
                for m in &mut members {
                    if m.slot == killer_slot {
                        m.kills += 1;
                        members_dirty = true;
                    }
                    if m.slot == victim_slot {
                        m.deaths += 1;
                        members_dirty = true;
                    }
                }
            }
        }

        if members_dirty {
            for m in &members {
                ctx.db.room_member().identity().update(m.clone());
            }
        }

        let victory = evaluate_victory(&room, &members, next_elapsed_ms);
        room.tick_count = next_tick;
        room.elapsed_ms = next_elapsed_ms;

        if let Some(winner_slot) = victory {
            room.status = STATUS_FINISHED;
            room.winner_slot = winner_slot;
            let room_id = room.id;
            ctx.db.room().id().update(room);
            delete_room_match_bunnies(ctx, room_id);
        } else {
            ctx.db.room().id().update(room);
        }
    }

    maybe_stop_match_schedule(ctx);
}

/// Returns a `Finished` room back to `Waiting` lobby state (host only).
#[spacetimedb::reducer]
pub fn return_to_lobby(ctx: &ReducerContext) -> Result<(), String> {
    let caller = ctx.sender();
    let (mut room, _member) = require_caller_room_and_member(ctx, caller)?;
    if room.host_identity != caller {
        return Err("Only the room host can return to the lobby".to_string());
    }
    if room.status != STATUS_FINISHED {
        return Err("Room is not in Finished status".to_string());
    }

    clear_room_match_entities(ctx, room.id);

    let members: Vec<RoomMember> = ctx
        .db
        .room_member()
        .room_id()
        .filter(&room.id)
        .collect();
    for mut m in members {
        m.kills = 0;
        m.deaths = 0;
        m.ready = m.identity == room.host_identity;
        ctx.db.room_member().identity().update(m);
    }

    room.status = STATUS_WAITING;
    room.tick_count = 0;
    room.elapsed_ms = 0;
    room.winner_slot = -1;
    ctx.db.room().id().update(room);
    Ok(())
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

fn default_nickname(identity: Identity) -> String {
    let bytes = identity.to_byte_array();
    format!("Bunny{:02X}{:02X}", bytes[0], bytes[1])
}

fn ensure_player(ctx: &ReducerContext, identity: Identity) -> Player {
    if let Some(player) = ctx.db.player().identity().find(identity) {
        return player;
    }
    ctx.db.player().insert(Player {
        identity,
        nickname: default_nickname(identity),
        connected: true,
        room_id: 0,
    })
}

fn generate_unique_room_code(ctx: &ReducerContext) -> Result<String, String> {
    let mut rng = ctx.rng();
    for _ in 0..64 {
        let mut buf = [0u8; ROOM_CODE_LEN];
        for b in &mut buf {
            let idx = rng.gen_range(0..CODE_ALPHABET.len());
            *b = CODE_ALPHABET[idx];
        }
        let code = String::from_utf8(buf.to_vec()).expect("ASCII code alphabet");
        if ctx.db.room().code().find(&code).is_none() {
            return Ok(code);
        }
    }
    Err("Failed to allocate unique room code".to_string())
}

fn join_room_internal(ctx: &ReducerContext, room: Room) -> Result<(), String> {
    if room.status != STATUS_WAITING {
        return Err("Room is locked (match already in progress or finished)".to_string());
    }

    let caller = ctx.sender();
    let members: Vec<RoomMember> = ctx
        .db
        .room_member()
        .room_id()
        .filter(&room.id)
        .collect();
    if members.iter().any(|m| m.identity == caller) {
        return Err("Already in this room".to_string());
    }
    if members.len() >= MAX_ROOM_PLAYERS {
        return Err("Room is full (max 4 players)".to_string());
    }

    let free_slot = (0..MAX_ROOM_PLAYERS as u8)
        .find(|&s| members.iter().all(|m| m.slot != s))
        .ok_or_else(|| "No free bunny slots available".to_string())?;

    remove_player_from_room(ctx, caller);

    let mut player = ensure_player(ctx, caller);
    player.room_id = room.id;
    let nickname = player.nickname.clone();
    ctx.db.player().identity().update(player);

    ctx.db.room_member().insert(RoomMember {
        identity: caller,
        room_id: room.id,
        slot: free_slot,
        nickname,
        ready: false,
        kills: 0,
        deaths: 0,
        is_bot: false,
    });
    Ok(())
}

fn bot_identity(room_id: u64, slot: u8) -> Identity {
    let mut bytes = [0u8; 32];
    bytes[0] = 0xB0;
    bytes[1] = 0x7B;
    bytes[2] = slot;
    bytes[8..16].copy_from_slice(&room_id.to_le_bytes());
    Identity::from_byte_array(bytes)
}

fn bot_name_for_slot(slot: u8) -> String {
    const NAMES: [&str; 4] = ["[BOT] Dott", "[BOT] Jiffy", "[BOT] Fizz", "[BOT] Mijji"];
    NAMES[slot as usize % NAMES.len()].to_string()
}

fn remove_player_from_room(ctx: &ReducerContext, identity: Identity) {
    if ctx.db.match_bunny().identity().find(identity).is_some() {
        ctx.db.match_bunny().identity().delete(identity);
    }

    if let Some(mut player) = ctx.db.player().identity().find(identity)
        && player.room_id != 0
    {
        player.room_id = 0;
        ctx.db.player().identity().update(player);
    }

    let Some(member) = ctx.db.room_member().identity().find(identity) else {
        return;
    };
    let room_id = member.room_id;
    ctx.db.room_member().identity().delete(identity);

    let Some(mut room) = ctx.db.room().id().find(room_id) else {
        maybe_stop_match_schedule(ctx);
        return;
    };

    let mut remaining: Vec<RoomMember> = ctx
        .db
        .room_member()
        .room_id()
        .filter(&room_id)
        .collect();
    if remaining.is_empty() || remaining.iter().all(|m| m.is_bot) {
        for bot in remaining {
            ctx.db.room_member().identity().delete(bot.identity);
        }
        clear_room_match_entities(ctx, room_id);
        ctx.db.room().id().delete(room_id);
        maybe_stop_match_schedule(ctx);
        return;
    }

    remaining.sort_by_key(|m| m.slot);
    if room.host_identity == identity
        && let Some(next_host) = remaining.iter().find(|m| !m.is_bot)
    {
        room.host_identity = next_host.identity;
    }

    if room.status == STATUS_IN_PROGRESS && remaining.len() == 1 {
        room.status = STATUS_FINISHED;
        room.winner_slot = remaining[0].slot as i8;
        delete_room_match_bunnies(ctx, room_id);
    }

    ctx.db.room().id().update(room);
    maybe_stop_match_schedule(ctx);
}

fn require_caller_room_and_member(
    ctx: &ReducerContext,
    caller: Identity,
) -> Result<(Room, RoomMember), String> {
    let member = ctx
        .db
        .room_member()
        .identity()
        .find(caller)
        .ok_or_else(|| "Caller is not in a room".to_string())?;
    let room = ctx
        .db
        .room()
        .id()
        .find(member.room_id)
        .ok_or_else(|| "Room not found".to_string())?;
    Ok((room, member))
}

fn delete_room_match_bunnies(ctx: &ReducerContext, room_id: u64) {
    let ids: Vec<Identity> = ctx
        .db
        .match_bunny()
        .room_id()
        .filter(&room_id)
        .map(|b| b.identity)
        .collect();
    for id in ids {
        ctx.db.match_bunny().identity().delete(id);
    }
}

fn clear_room_match_entities(ctx: &ReducerContext, room_id: u64) {
    delete_room_match_bunnies(ctx, room_id);
    let kill_ids: Vec<u64> = ctx
        .db
        .kill_event()
        .room_id()
        .filter(&room_id)
        .map(|k| k.id)
        .collect();
    for id in kill_ids {
        ctx.db.kill_event().id().delete(id);
    }
}

fn ensure_match_schedule_running(ctx: &ReducerContext) {
    if ctx.db.match_tick_schedule().count() == 0 {
        let interval = TimeDuration::from_micros((TICK_INTERVAL_MS * 1000) as i64);
        ctx.db.match_tick_schedule().insert(MatchTickSchedule {
            scheduled_id: 0,
            scheduled_at: ScheduleAt::Interval(interval),
        });
    }
}

fn maybe_stop_match_schedule(ctx: &ReducerContext) {
    if ctx
        .db
        .room()
        .status()
        .filter(&STATUS_IN_PROGRESS)
        .next()
        .is_none()
    {
        stop_match_schedule(ctx);
    }
}

fn stop_match_schedule(ctx: &ReducerContext) {
    let ids: Vec<u64> = ctx
        .db
        .match_tick_schedule()
        .iter()
        .map(|row| row.scheduled_id)
        .collect();
    for id in ids {
        ctx.db.match_tick_schedule().scheduled_id().delete(id);
    }
}

fn pick_top_ranked_slot(mut candidates: Vec<&RoomMember>) -> i8 {
    if candidates.is_empty() {
        return -1;
    }
    candidates.sort_by(|a, b| {
        b.kills
            .cmp(&a.kills)
            .then_with(|| a.deaths.cmp(&b.deaths))
            .then_with(|| a.slot.cmp(&b.slot))
    });
    if candidates.len() >= 2
        && candidates[0].kills == candidates[1].kills
        && candidates[0].deaths == candidates[1].deaths
    {
        -1
    } else {
        candidates[0].slot as i8
    }
}

fn evaluate_victory(room: &Room, members: &[RoomMember], next_elapsed_ms: u32) -> Option<i8> {
    if members.is_empty() {
        return Some(-1);
    }

    match room.win_mode {
        WIN_MODE_KILLS => {
            let qualifiers: Vec<&RoomMember> = members
                .iter()
                .filter(|m| m.kills >= room.win_target)
                .collect();
            if qualifiers.is_empty() {
                None
            } else {
                Some(pick_top_ranked_slot(qualifiers))
            }
        }
        WIN_MODE_TIME => {
            if next_elapsed_ms < room.win_target.saturating_mul(1000) {
                None
            } else {
                Some(pick_top_ranked_slot(members.iter().collect()))
            }
        }
        _ => None,
    }
}

fn match_bunny_to_sim(mb: &MatchBunny) -> sim::BunnyState {
    sim::BunnyState {
        slot: mb.slot,
        x: mb.x,
        y: mb.y,
        vx: mb.vx,
        vy: mb.vy,
        facing: mb.facing,
        alive: mb.alive,
        respawn_ticks: mb.respawn_ticks,
        invuln_ticks: mb.invuln_ticks,
        on_ground: mb.on_ground,
        in_water: mb.in_water,
        on_ice: mb.on_ice,
        prev_jump: mb.prev_jump,
        input_bits: mb.input_bits,
    }
}

fn bunny_state_differs(mb: &MatchBunny, s: &sim::BunnyState) -> bool {
    mb.x != s.x
        || mb.y != s.y
        || mb.vx != s.vx
        || mb.vy != s.vy
        || mb.facing != s.facing
        || mb.alive != s.alive
        || mb.respawn_ticks != s.respawn_ticks
        || mb.invuln_ticks != s.invuln_ticks
        || mb.on_ground != s.on_ground
        || mb.in_water != s.in_water
        || mb.on_ice != s.on_ice
        || mb.prev_jump != s.prev_jump
}

fn apply_sim_to_match_bunny(mb: &mut MatchBunny, s: &sim::BunnyState) {
    mb.x = s.x;
    mb.y = s.y;
    mb.vx = s.vx;
    mb.vy = s.vy;
    mb.facing = s.facing;
    mb.alive = s.alive;
    mb.respawn_ticks = s.respawn_ticks;
    mb.invuln_ticks = s.invuln_ticks;
    mb.on_ground = s.on_ground;
    mb.in_water = s.in_water;
    mb.on_ice = s.on_ice;
    mb.prev_jump = s.prev_jump;
}

#[cfg(test)]
mod tests {
    use super::*;

    fn test_identity(seed: u8) -> Identity {
        Identity::from_byte_array([seed; 32])
    }

    fn test_room(win_mode: u8, win_target: u32) -> Room {
        Room {
            id: 1,
            code: "ABCDE".to_string(),
            name: "Meadow".to_string(),
            is_public: true,
            host_identity: test_identity(1),
            status: STATUS_IN_PROGRESS,
            win_mode,
            win_target,
            mut_low_gravity: false,
            mut_pogo: false,
            mut_jetpack: false,
            gore_enabled: true,
            tick_count: 0,
            elapsed_ms: 0,
            winner_slot: -1,
        }
    }

    fn test_member(slot: u8, kills: u32, deaths: u32) -> RoomMember {
        RoomMember {
            identity: test_identity(slot + 10),
            room_id: 1,
            slot,
            nickname: format!("B{slot}"),
            ready: true,
            kills,
            deaths,
            is_bot: false,
        }
    }

    #[test]
    fn evaluate_victory_kills_and_tiebreak() {
        let room = test_room(WIN_MODE_KILLS, 5);
        let below = [test_member(0, 4, 1), test_member(1, 2, 4)];
        assert_eq!(evaluate_victory(&room, &below, 1000), None);

        let clear = [test_member(0, 4, 1), test_member(2, 5, 2)];
        assert_eq!(evaluate_victory(&room, &clear, 1000), Some(2));

        let tie_broken_by_deaths = [test_member(0, 5, 3), test_member(1, 5, 1)];
        assert_eq!(evaluate_victory(&room, &tie_broken_by_deaths, 1000), Some(1));

        let exact_tie = [test_member(0, 5, 2), test_member(1, 5, 2)];
        assert_eq!(evaluate_victory(&room, &exact_tie, 1000), Some(-1));
    }

    #[test]
    fn evaluate_victory_time_mode() {
        let room = test_room(WIN_MODE_TIME, 10);
        let members = [test_member(0, 2, 1), test_member(1, 3, 2)];
        assert_eq!(evaluate_victory(&room, &members, 9999), None);
        assert_eq!(evaluate_victory(&room, &members, 10000), Some(1));

        let draw = [test_member(0, 2, 2), test_member(1, 2, 2)];
        assert_eq!(evaluate_victory(&room, &draw, 10000), Some(-1));
    }

    #[test]
    fn match_bunny_roundtrip_and_diff() {
        let mut mb = MatchBunny {
            identity: test_identity(7),
            room_id: 1,
            slot: 2,
            x: 10.0,
            y: 20.0,
            vx: 0.0,
            vy: 0.0,
            facing: 1,
            alive: true,
            respawn_ticks: 0,
            invuln_ticks: 15,
            on_ground: false,
            in_water: false,
            on_ice: false,
            prev_jump: false,
            input_bits: 2,
            last_seq: 9,
            is_bot: false,
        };
        let mut sim_state = match_bunny_to_sim(&mb);
        assert!(!bunny_state_differs(&mb, &sim_state));
        sim_state.x = 12.5;
        sim_state.invuln_ticks = 14;
        assert!(bunny_state_differs(&mb, &sim_state));
        apply_sim_to_match_bunny(&mut mb, &sim_state);
        assert!(!bunny_state_differs(&mb, &sim_state));
        assert_eq!(mb.x, 12.5);
        assert_eq!(mb.invuln_ticks, 14);
        assert_eq!(mb.last_seq, 9);
    }
}
