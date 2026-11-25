//! Pure deterministic simulation crate for Jumper 'n Bumper.
//!
//! This crate has zero SpacetimeDB dependencies and embeds the shared arena
//! and physics constants from `shared/` so server physics and unit tests
//! execute against the exact same configuration used by the Godot client.

use serde::{Deserialize, Serialize};

const PHYSICS_CONSTANTS_JSON: &str = include_str!("../../../shared/physics_constants.json");
const CLASSIC_MEADOW_JSON: &str = include_str!("../../../shared/classic_meadow.json");

/// Small epsilon used when shrinking orthogonal AABB collision queries to
/// prevent edge-touching faces from catching on adjacent perpendicular tiles.
const COLLISION_EPS: f32 = 0.005;

/// Minimum vertical separation (in pixels) between two overlapping bunnies
/// required for the upper bunny to stomp the lower bunny.
const STOMP_MIN_VERTICAL_SEP: f32 = 4.0;

/// Returns the fixed server simulation tick rate in Hz.
pub const fn tick_rate_hz() -> u32 {
    30
}

/// Bitmask constants for player movement and jump input.
pub struct InputBits;

impl InputBits {
    pub const LEFT: u8 = 1;
    pub const RIGHT: u8 = 2;
    pub const JUMP: u8 = 4;
}

/// Tile types used in arena grids.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[repr(u8)]
pub enum TileKind {
    Empty = 0,
    SolidGrassDirt = 1,
    SolidStonePlatform = 2,
    Water = 3,
    Ice = 4,
    Spring = 5,
}

impl TileKind {
    /// Converts a raw integer tile ID from JSON into a `TileKind`.
    pub fn from_u8(value: u8) -> Option<Self> {
        match value {
            0 => Some(Self::Empty),
            1 => Some(Self::SolidGrassDirt),
            2 => Some(Self::SolidStonePlatform),
            3 => Some(Self::Water),
            4 => Some(Self::Ice),
            5 => Some(Self::Spring),
            _ => None,
        }
    }

    /// Returns `true` if this tile blocks bunny movement.
    pub const fn is_solid(self) -> bool {
        matches!(
            self,
            Self::SolidGrassDirt | Self::SolidStonePlatform | Self::Ice | Self::Spring
        )
    }
}

/// Shared arena, tick, hitbox, and physics constants loaded from `shared/physics_constants.json`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct PhysicsConstants {
    pub width: f32,
    pub height: f32,
    pub tile_size: f32,
    pub cols: usize,
    pub rows: usize,
    pub tick_rate_hz: u32,
    pub substeps: u32,
    pub bunny_width: f32,
    pub bunny_height: f32,
    pub spawn_invuln_ticks: u16,
    pub respawn_ticks: u16,
    pub max_run_speed: f32,
    pub ground_accel: f32,
    pub ground_decel: f32,
    pub air_accel: f32,
    pub air_decel: f32,
    pub ice_accel: f32,
    pub ice_decel: f32,
    pub gravity: f32,
    pub low_gravity_scale: f32,
    pub max_fall_speed: f32,
    pub jump_velocity: f32,
    pub stomp_rebound_velocity: f32,
    pub spring_velocity: f32,
    pub water_gravity_scale: f32,
    pub water_max_fall: f32,
    pub water_swim_velocity: f32,
    pub jetpack_accel: f32,
    pub jetpack_max_rise: f32,
}

impl PhysicsConstants {
    /// Loads the embedded shared physics constants from `shared/physics_constants.json`.
    pub fn default_shared() -> Self {
        serde_json::from_str(PHYSICS_CONSTANTS_JSON)
            .expect("embedded shared/physics_constants.json must be valid")
    }

    /// Returns the fixed simulation delta-time per physics substep in seconds.
    pub fn substep_dt(&self) -> f32 {
        let hz = self.tick_rate_hz.max(1) as f32;
        let sub = self.substeps.max(1) as f32;
        1.0 / (hz * sub)
    }
}

/// Tilemap arena layout and spawn points.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Arena {
    pub name: String,
    pub cols: usize,
    pub tile_size: f32,
    pub rows: Vec<Vec<u8>>,
    pub spawn_points: Vec<[f32; 2]>,
}

impl Arena {
    /// Loads the embedded Classic Meadow arena from `shared/classic_meadow.json`.
    pub fn classic_meadow() -> Self {
        serde_json::from_str(CLASSIC_MEADOW_JSON)
            .expect("embedded shared/classic_meadow.json must be valid")
    }

    /// Returns the tile kind at `(col, row)`, or `TileKind::Empty` if out of bounds.
    pub fn tile_at(&self, col: isize, row: isize) -> TileKind {
        if col < 0 || row < 0 {
            return TileKind::Empty;
        }
        let (c, r) = (col as usize, row as usize);
        if r >= self.rows.len() || c >= self.rows[r].len() {
            return TileKind::Empty;
        }
        TileKind::from_u8(self.rows[r][c]).unwrap_or(TileKind::Empty)
    }

    /// Returns `true` if the tile at `(col, row)` is solid.
    pub fn is_solid_at(&self, col: isize, row: isize) -> bool {
        self.tile_at(col, row).is_solid()
    }

    /// Validates dimensions, tile IDs, and spawn point safety against `constants`.
    pub fn validate(&self, constants: &PhysicsConstants) -> Result<(), String> {
        if self.cols != constants.cols {
            return Err(format!(
                "arena cols {} != constants cols {}",
                self.cols, constants.cols
            ));
        }
        if self.rows.len() != constants.rows {
            return Err(format!(
                "arena rows {} != constants rows {}",
                self.rows.len(),
                constants.rows
            ));
        }
        for (r, row) in self.rows.iter().enumerate() {
            if row.len() != constants.cols {
                return Err(format!(
                    "row {r} length {} != {}",
                    row.len(),
                    constants.cols
                ));
            }
            for (c, &tile) in row.iter().enumerate() {
                if TileKind::from_u8(tile).is_none() {
                    return Err(format!("invalid tile id {tile} at ({c}, {r})"));
                }
            }
        }
        if self.spawn_points.is_empty() {
            return Err("arena must define at least one spawn point".to_string());
        }
        for (idx, &[sx, sy]) in self.spawn_points.iter().enumerate() {
            if sx < 0.0
                || sy < 0.0
                || sx + constants.bunny_width > constants.width
                || sy + constants.bunny_height > constants.height
            {
                return Err(format!("spawn point {idx} ({sx}, {sy}) out of arena bounds"));
            }
            let min_c = (sx / self.tile_size).floor() as isize;
            let max_c = ((sx + constants.bunny_width - COLLISION_EPS) / self.tile_size).floor() as isize;
            let min_r = (sy / self.tile_size).floor() as isize;
            let max_r = ((sy + constants.bunny_height - COLLISION_EPS) / self.tile_size).floor() as isize;
            for r in min_r..=max_r {
                for c in min_c..=max_c {
                    if self.tile_at(c, r) != TileKind::Empty {
                        return Err(format!(
                            "spawn point {idx} ({sx}, {sy}) overlaps non-empty tile {:?} at ({c}, {r})",
                            self.tile_at(c, r)
                        ));
                    }
                }
            }
            // Ensure spawn rests directly above or close to a solid non-spring platform.
            let support_r = ((sy + constants.bunny_height + 2.0) / self.tile_size).floor() as isize;
            let mut has_support = false;
            for c in min_c..=max_c {
                let tile = self.tile_at(c, support_r);
                if tile.is_solid() && tile != TileKind::Spring {
                    has_support = true;
                }
            }
            if !has_support {
                return Err(format!(
                    "spawn point {idx} ({sx}, {sy}) lacks solid platform support below"
                ));
            }
        }
        Ok(())
    }
}

/// Optional match gameplay mutators.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Mutators {
    pub low_gravity: bool,
    pub pogo: bool,
    pub jetpack: bool,
}

/// Per-bunny authoritative simulation state.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct BunnyState {
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
}

impl BunnyState {
    /// Creates an alive bunny resting at `(x, y)` with zero velocity.
    pub fn new(slot: u8, x: f32, y: f32) -> Self {
        Self {
            slot,
            x,
            y,
            vx: 0.0,
            vy: 0.0,
            facing: 1,
            alive: true,
            respawn_ticks: 0,
            invuln_ticks: 0,
            on_ground: false,
            in_water: false,
            on_ice: false,
            prev_jump: false,
            input_bits: 0,
        }
    }
}

/// Discrete gameplay events emitted during a `step_room` tick.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub enum StepEvent {
    Jumped {
        slot: u8,
    },
    Sprung {
        slot: u8,
        x: f32,
        y: f32,
    },
    WaterSplash {
        slot: u8,
        x: f32,
        y: f32,
    },
    Killed {
        killer_slot: u8,
        victim_slot: u8,
        x: f32,
        y: f32,
    },
    Respawned {
        slot: u8,
        x: f32,
        y: f32,
    },
}

/// Advances one 30 Hz server tick across all bunnies in a room.
pub fn step_room(
    bunnies: &mut [BunnyState],
    arena: &Arena,
    constants: &PhysicsConstants,
    mutators: &Mutators,
    tick: u64,
) -> Vec<StepEvent> {
    let mut events = Vec::new();
    process_timers_and_respawns(bunnies, arena, constants, tick, &mut events);

    let substeps = constants.substeps.max(1);
    let dt = constants.substep_dt();

    // Capture edge-triggered jump state once for this 30 Hz tick.
    let jump_just_pressed: Vec<bool> = bunnies
        .iter()
        .map(|b| b.alive && (b.input_bits & InputBits::JUMP) != 0 && !b.prev_jump)
        .collect();

    for substep in 0..substeps {
        for (idx, bunny) in bunnies.iter_mut().enumerate() {
            if !bunny.alive {
                continue;
            }
            let pressed = substep == 0 && jump_just_pressed[idx];
            step_bunny_substep(bunny, arena, constants, mutators, dt, pressed, &mut events);
        }
        resolve_bunny_collisions(bunnies, arena, constants, &mut events);
    }

    for bunny in bunnies.iter_mut() {
        bunny.prev_jump = (bunny.input_bits & InputBits::JUMP) != 0;
    }

    events
}

fn process_timers_and_respawns(
    bunnies: &mut [BunnyState],
    arena: &Arena,
    constants: &PhysicsConstants,
    tick: u64,
    events: &mut Vec<StepEvent>,
) {
    for i in 0..bunnies.len() {
        if bunnies[i].alive {
            if bunnies[i].invuln_ticks > 0 {
                bunnies[i].invuln_ticks -= 1;
            }
            continue;
        }

        if bunnies[i].respawn_ticks > 0 {
            bunnies[i].respawn_ticks -= 1;
        }
        if bunnies[i].respawn_ticks == 0 {
            let [sx, sy] = choose_safest_spawn(bunnies, i, arena, constants, tick);
            let slot = bunnies[i].slot;
            let jump_held = (bunnies[i].input_bits & InputBits::JUMP) != 0;
            let b = &mut bunnies[i];
            b.x = sx;
            b.y = sy;
            b.vx = 0.0;
            b.vy = 0.0;
            b.alive = true;
            b.invuln_ticks = constants.spawn_invuln_ticks;
            b.on_ground = false;
            b.in_water = false;
            b.on_ice = false;
            b.prev_jump = jump_held;
            events.push(StepEvent::Respawned { slot, x: sx, y: sy });
        }
    }
}

/// Picks the spawn point maximizing minimum squared distance to all alive opponents.
fn choose_safest_spawn(
    bunnies: &[BunnyState],
    respawning_idx: usize,
    arena: &Arena,
    constants: &PhysicsConstants,
    tick: u64,
) -> [f32; 2] {
    if arena.spawn_points.is_empty() {
        return [0.0, 0.0];
    }
    let alive_centers: Vec<(f32, f32)> = bunnies
        .iter()
        .enumerate()
        .filter(|&(idx, b)| idx != respawning_idx && b.alive)
        .map(|(_, b)| {
            (
                b.x + constants.bunny_width * 0.5,
                b.y + constants.bunny_height * 0.5,
            )
        })
        .collect();

    if alive_centers.is_empty() {
        let idx = (bunnies[respawning_idx].slot as usize + tick as usize) % arena.spawn_points.len();
        return arena.spawn_points[idx];
    }

    let mut best_spawn = arena.spawn_points[0];
    let mut best_min_dist_sq = -1.0_f32;

    for &[sx, sy] in &arena.spawn_points {
        let cx = sx + constants.bunny_width * 0.5;
        let cy = sy + constants.bunny_height * 0.5;
        let min_dist_sq = alive_centers
            .iter()
            .map(|&(ox, oy)| {
                let dx = cx - ox;
                let dy = cy - oy;
                dx * dx + dy * dy
            })
            .fold(f32::INFINITY, f32::min);

        if min_dist_sq > best_min_dist_sq {
            best_min_dist_sq = min_dist_sq;
            best_spawn = [sx, sy];
        }
    }

    best_spawn
}

fn step_bunny_substep(
    bunny: &mut BunnyState,
    arena: &Arena,
    constants: &PhysicsConstants,
    mutators: &Mutators,
    dt: f32,
    jump_just_pressed: bool,
    events: &mut Vec<StepEvent>,
) {
    // Refresh ground/water flags before decision-making so newly spawned or
    // positioned bunnies react immediately on their first tick.
    if bunny.vy >= 0.0 {
        let (on_ground, on_ice, _) = probe_underfoot(bunny, arena, constants);
        bunny.on_ground = on_ground;
        bunny.on_ice = on_ice;
    }
    bunny.in_water = check_water_overlap(bunny, arena, constants);

    apply_horizontal_velocity(bunny, constants, dt);
    apply_vertical_and_jump(bunny, constants, mutators, dt, jump_just_pressed, events);

    move_and_collide_x(bunny, arena, constants, dt);
    move_and_collide_y(bunny, arena, constants, dt);

    // Refresh underfoot state (ground, ice, spring) after vertical resolution.
    if bunny.vy >= 0.0 {
        let (on_ground, on_ice, on_spring) = probe_underfoot(bunny, arena, constants);
        bunny.on_ground = on_ground;
        bunny.on_ice = on_ice;
        if on_spring {
            bunny.vy = constants.spring_velocity;
            bunny.on_ground = false;
            bunny.on_ice = false;
            events.push(StepEvent::Sprung {
                slot: bunny.slot,
                x: bunny.x + constants.bunny_width * 0.5,
                y: bunny.y + constants.bunny_height,
            });
        }
    } else {
        bunny.on_ground = false;
        bunny.on_ice = false;
    }

    let now_in_water = check_water_overlap(bunny, arena, constants);
    if now_in_water != bunny.in_water {
        events.push(StepEvent::WaterSplash {
            slot: bunny.slot,
            x: bunny.x + constants.bunny_width * 0.5,
            y: bunny.y + constants.bunny_height * 0.5,
        });
    }
    bunny.in_water = now_in_water;
}

fn apply_horizontal_velocity(bunny: &mut BunnyState, constants: &PhysicsConstants, dt: f32) {
    let left = (bunny.input_bits & InputBits::LEFT) != 0;
    let right = (bunny.input_bits & InputBits::RIGHT) != 0;
    let move_dir = match (left, right) {
        (true, false) => -1.0_f32,
        (false, true) => 1.0_f32,
        _ => 0.0_f32,
    };

    if move_dir < 0.0 {
        bunny.facing = -1;
    } else if move_dir > 0.0 {
        bunny.facing = 1;
    }

    let (accel, decel) = if bunny.on_ground && bunny.on_ice {
        (constants.ice_accel, constants.ice_decel)
    } else if bunny.on_ground {
        (constants.ground_accel, constants.ground_decel)
    } else {
        (constants.air_accel, constants.air_decel)
    };

    if move_dir != 0.0 {
        let target_vx = move_dir * constants.max_run_speed;
        let opposing = bunny.vx * move_dir < 0.0;
        // Ice keeps low acceleration even when reversing so skidding feels authentic.
        let rate = if !bunny.on_ice && opposing {
            accel.max(decel)
        } else {
            accel
        };
        bunny.vx = move_toward(bunny.vx, target_vx, rate * dt);
    } else {
        bunny.vx = move_toward(bunny.vx, 0.0, decel * dt);
    }
}

fn apply_vertical_and_jump(
    bunny: &mut BunnyState,
    constants: &PhysicsConstants,
    mutators: &Mutators,
    dt: f32,
    jump_just_pressed: bool,
    events: &mut Vec<StepEvent>,
) {
    let jump_held = (bunny.input_bits & InputBits::JUMP) != 0;

    if bunny.in_water {
        // Swim upward on jump press or continuous paddle while holding jump.
        if jump_just_pressed || (jump_held && bunny.vy > constants.water_swim_velocity * 0.45) {
            bunny.vy = constants.water_swim_velocity;
            if jump_just_pressed {
                events.push(StepEvent::Jumped { slot: bunny.slot });
            }
        }
    } else if bunny.on_ground && (jump_just_pressed || mutators.pogo) {
        bunny.vy = constants.jump_velocity;
        bunny.on_ground = false;
        bunny.on_ice = false;
        events.push(StepEvent::Jumped { slot: bunny.slot });
    }

    let base_gravity = if mutators.low_gravity {
        constants.gravity * constants.low_gravity_scale
    } else {
        constants.gravity
    };

    if bunny.in_water {
        bunny.vy = (bunny.vy + base_gravity * constants.water_gravity_scale * dt)
            .min(constants.water_max_fall);
    } else {
        bunny.vy = (bunny.vy + base_gravity * dt).min(constants.max_fall_speed);
    }

    if mutators.jetpack && jump_held {
        if bunny.vy > constants.jetpack_max_rise {
            bunny.vy = (bunny.vy - constants.jetpack_accel * dt).max(constants.jetpack_max_rise);
        }
        bunny.on_ground = false;
    }
}

fn move_and_collide_x(
    bunny: &mut BunnyState,
    arena: &Arena,
    constants: &PhysicsConstants,
    dt: f32,
) {
    bunny.x += bunny.vx * dt;

    let max_x = constants.width - constants.bunny_width;
    if bunny.x < 0.0 {
        bunny.x = 0.0;
        bunny.vx = 0.0;
    } else if bunny.x > max_x {
        bunny.x = max_x;
        bunny.vx = 0.0;
    }

    let ts = arena.tile_size;
    let w = constants.bunny_width;
    let h = constants.bunny_height;

    let min_col = (bunny.x / ts).floor() as isize;
    let max_col = ((bunny.x + w - COLLISION_EPS) / ts).floor() as isize;
    let min_row = ((bunny.y + COLLISION_EPS) / ts).floor() as isize;
    let max_row = ((bunny.y + h - COLLISION_EPS) / ts).floor() as isize;

    for row in min_row..=max_row {
        for col in min_col..=max_col {
            if arena.is_solid_at(col, row) {
                if bunny.vx > 0.0 {
                    let tile_left = col as f32 * ts;
                    bunny.x = bunny.x.min(tile_left - w);
                } else if bunny.vx < 0.0 {
                    let tile_right = (col + 1) as f32 * ts;
                    bunny.x = bunny.x.max(tile_right);
                }
                bunny.vx = 0.0;
                return;
            }
        }
    }
}

fn move_and_collide_y(
    bunny: &mut BunnyState,
    arena: &Arena,
    constants: &PhysicsConstants,
    dt: f32,
) {
    bunny.y += bunny.vy * dt;
    bunny.on_ground = false;
    bunny.on_ice = false;

    if bunny.y < 0.0 {
        bunny.y = 0.0;
        if bunny.vy < 0.0 {
            bunny.vy = 0.0;
        }
    }
    let max_y = constants.height - constants.bunny_height;
    if bunny.y >= max_y {
        bunny.y = max_y;
        if bunny.vy >= 0.0 {
            bunny.vy = 0.0;
            bunny.on_ground = true;
        }
    }

    let ts = arena.tile_size;
    let w = constants.bunny_width;
    let h = constants.bunny_height;

    let min_col = ((bunny.x + COLLISION_EPS) / ts).floor() as isize;
    let max_col = ((bunny.x + w - COLLISION_EPS) / ts).floor() as isize;
    let min_row = (bunny.y / ts).floor() as isize;
    let max_row = ((bunny.y + h - COLLISION_EPS) / ts).floor() as isize;

    let mut hit_top: Option<f32> = None;
    let mut hit_bottom: Option<f32> = None;

    for row in min_row..=max_row {
        for col in min_col..=max_col {
            if arena.is_solid_at(col, row) {
                if bunny.vy > 0.0 {
                    let tile_top = row as f32 * ts;
                    hit_top = Some(hit_top.map_or(tile_top, |cur| cur.min(tile_top)));
                } else if bunny.vy < 0.0 {
                    let tile_bottom = (row + 1) as f32 * ts;
                    hit_bottom = Some(hit_bottom.map_or(tile_bottom, |cur| cur.max(tile_bottom)));
                }
            }
        }
    }

    if let Some(tile_top) = hit_top {
        bunny.y = tile_top - h;
        bunny.vy = 0.0;
        bunny.on_ground = true;
    } else if let Some(tile_bottom) = hit_bottom {
        bunny.y = tile_bottom;
        bunny.vy = 0.0;
    }
}

/// Probes directly beneath the bunny's feet (`y + height + 0.05`) for ground, ice, and springs.
fn probe_underfoot(
    bunny: &BunnyState,
    arena: &Arena,
    constants: &PhysicsConstants,
) -> (bool, bool, bool) {
    let ts = arena.tile_size;
    let w = constants.bunny_width;
    let h = constants.bunny_height;

    if bunny.y + h >= constants.height - 0.05 {
        return (true, false, false);
    }

    let probe_y = bunny.y + h + 0.05;
    let row = (probe_y / ts).floor() as isize;
    let tile_top = row as f32 * ts;
    // Must actually be resting on the tile's top surface rather than deep inside a tile.
    if (bunny.y + h - tile_top).abs() > 0.1 {
        return (false, false, false);
    }

    let min_col = ((bunny.x + COLLISION_EPS) / ts).floor() as isize;
    let max_col = ((bunny.x + w - COLLISION_EPS) / ts).floor() as isize;

    let mut on_ground = false;
    let mut on_ice = false;
    let mut on_spring = false;

    for col in min_col..=max_col {
        let tile = arena.tile_at(col, row);
        if tile.is_solid() {
            on_ground = true;
        }
        if tile == TileKind::Ice {
            on_ice = true;
        }
        if tile == TileKind::Spring {
            on_spring = true;
        }
    }

    (on_ground, on_ice, on_spring)
}

fn check_water_overlap(
    bunny: &BunnyState,
    arena: &Arena,
    constants: &PhysicsConstants,
) -> bool {
    let ts = arena.tile_size;
    let min_col = ((bunny.x + 1.0) / ts).floor() as isize;
    let max_col = ((bunny.x + constants.bunny_width - 1.0) / ts).floor() as isize;
    let min_row = ((bunny.y + 1.0) / ts).floor() as isize;
    let max_row = ((bunny.y + constants.bunny_height - 1.0) / ts).floor() as isize;

    for row in min_row..=max_row {
        for col in min_col..=max_col {
            if arena.tile_at(col, row) == TileKind::Water {
                return true;
            }
        }
    }
    false
}

/// Resolves head-stomps and non-lethal side bumps between alive, non-invulnerable bunnies.
///
/// Uses a two-pass algorithm over pre-collision snapshots so simultaneous stomps
/// and vertical stacks behave identically regardless of slice ordering.
fn resolve_bunny_collisions(
    bunnies: &mut [BunnyState],
    arena: &Arena,
    constants: &PhysicsConstants,
    events: &mut Vec<StepEvent>,
) {
    let w = constants.bunny_width;
    let h = constants.bunny_height;
    let len = bunnies.len();

    // Snapshot pre-collision state for order-independent stomp detection.
    let snap: Vec<(f32, f32, f32, bool)> = bunnies
        .iter()
        .map(|b| (b.x, b.y, b.vy, b.alive && b.invuln_ticks == 0))
        .collect();

    // Pass 1: Identify all stomp pairs against the snapshot.
    let mut stomp_pairs: Vec<(usize, usize)> = Vec::new();
    for i in 0..len {
        for j in (i + 1)..len {
            if !snap[i].3 || !snap[j].3 {
                continue;
            }
            let overlap_x = snap[i].0 < snap[j].0 + w && snap[i].0 + w > snap[j].0;
            let overlap_y = snap[i].1 < snap[j].1 + h && snap[i].1 + h > snap[j].1;
            if !overlap_x || !overlap_y {
                continue;
            }

            let (top_idx, bot_idx) = if snap[i].1 <= snap[j].1 {
                (i, j)
            } else {
                (j, i)
            };

            let vertical_sep = snap[bot_idx].1 - snap[top_idx].1;
            let descending_onto =
                snap[top_idx].2 > 0.0 || snap[top_idx].2 > snap[bot_idx].2;

            if vertical_sep >= STOMP_MIN_VERTICAL_SEP && descending_onto {
                stomp_pairs.push((top_idx, bot_idx));
            }
        }
    }

    // Sort deterministically by (killer_slot, victim_slot) so event ordering
    // and multi-killer tie-breaking are independent of slice order.
    stomp_pairs.sort_by_key(|&(k, v)| (bunnies[k].slot, bunnies[v].slot));

    let mut stomped = vec![false; len];
    let mut rebounded = vec![false; len];

    for (killer_idx, victim_idx) in stomp_pairs {
        rebounded[killer_idx] = true;
        if stomped[victim_idx] {
            continue;
        }
        stomped[victim_idx] = true;

        let killer_slot = bunnies[killer_idx].slot;
        let victim_slot = bunnies[victim_idx].slot;
        let death_x = snap[victim_idx].0 + w * 0.5;
        let death_y = snap[victim_idx].1 + h * 0.5;

        bunnies[victim_idx].alive = false;
        bunnies[victim_idx].respawn_ticks = constants.respawn_ticks;
        bunnies[victim_idx].vx = 0.0;
        bunnies[victim_idx].vy = 0.0;

        events.push(StepEvent::Killed {
            killer_slot,
            victim_slot,
            x: death_x,
            y: death_y,
        });
    }

    for (idx, bunny) in bunnies.iter_mut().enumerate() {
        if rebounded[idx] && bunny.alive {
            bunny.vy = constants.stomp_rebound_velocity;
            bunny.on_ground = false;
        }
    }

    // Pass 2: Non-lethal horizontal side bumps among surviving bunnies.
    for i in 0..len {
        for j in (i + 1)..len {
            if !bunnies[i].alive || !bunnies[j].alive {
                continue;
            }
            if bunnies[i].invuln_ticks > 0 || bunnies[j].invuln_ticks > 0 {
                continue;
            }

            let overlap_x = bunnies[i].x < bunnies[j].x + w && bunnies[i].x + w > bunnies[j].x;
            let overlap_y = bunnies[i].y < bunnies[j].y + h && bunnies[i].y + h > bunnies[j].y;
            if !overlap_x || !overlap_y {
                continue;
            }

            let pen_x =
                (bunnies[i].x + w).min(bunnies[j].x + w) - bunnies[i].x.max(bunnies[j].x);
            let push = (pen_x * 0.5).max(0.5);

            let i_left = if (bunnies[i].x - bunnies[j].x).abs() < 0.001 {
                bunnies[i].slot < bunnies[j].slot
            } else {
                bunnies[i].x < bunnies[j].x
            };
            let (left_idx, right_idx) = if i_left { (i, j) } else { (j, i) };

            bunnies[left_idx].x -= push;
            bunnies[right_idx].x += push;
            clamp_and_depentrate_x(&mut bunnies[left_idx], arena, constants);
            clamp_and_depentrate_x(&mut bunnies[right_idx], arena, constants);

            if bunnies[left_idx].vx > 0.0 {
                bunnies[left_idx].vx = 0.0;
            }
            if bunnies[right_idx].vx < 0.0 {
                bunnies[right_idx].vx = 0.0;
            }
        }
    }
}

/// Ensures side-bump separation never pushes a bunny outside arena bounds or into a solid wall.
fn clamp_and_depentrate_x(
    bunny: &mut BunnyState,
    arena: &Arena,
    constants: &PhysicsConstants,
) {
    let max_x = constants.width - constants.bunny_width;
    bunny.x = bunny.x.clamp(0.0, max_x);

    let ts = arena.tile_size;
    let w = constants.bunny_width;
    let h = constants.bunny_height;
    let min_col = (bunny.x / ts).floor() as isize;
    let max_col = ((bunny.x + w - COLLISION_EPS) / ts).floor() as isize;
    let min_row = ((bunny.y + COLLISION_EPS) / ts).floor() as isize;
    let max_row = ((bunny.y + h - COLLISION_EPS) / ts).floor() as isize;

    for row in min_row..=max_row {
        for col in min_col..=max_col {
            if arena.is_solid_at(col, row) {
                let tile_left = col as f32 * ts;
                let tile_right = (col + 1) as f32 * ts;
                let center = bunny.x + w * 0.5;
                let tile_center = tile_left + ts * 0.5;
                if center < tile_center {
                    bunny.x = (tile_left - w).clamp(0.0, max_x);
                } else {
                    bunny.x = tile_right.clamp(0.0, max_x);
                }
            }
        }
    }
}

fn move_toward(current: f32, target: f32, max_delta: f32) -> f32 {
    if (target - current).abs() <= max_delta {
        target
    } else if target > current {
        current + max_delta
    } else {
        current - max_delta
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn test_env() -> (Arena, PhysicsConstants) {
        (Arena::classic_meadow(), PhysicsConstants::default_shared())
    }

    #[test]
    fn sanity_constants_and_tick_rate() {
        let c = PhysicsConstants::default_shared();
        assert_eq!(tick_rate_hz(), 30);
        assert_eq!(c.tick_rate_hz, 30);
        assert_eq!(c.substeps, 2);
        assert_eq!(c.width, 400.0);
        assert_eq!(c.height, 256.0);
        assert_eq!(c.tile_size, 16.0);
        assert_eq!(c.cols, 25);
        assert_eq!(c.rows, 16);
        assert_eq!(c.bunny_width, 14.0);
        assert_eq!(c.bunny_height, 14.0);
        assert_eq!(c.spawn_invuln_ticks, 15);
        assert_eq!(c.respawn_ticks, 45);
    }

    #[test]
    fn classic_meadow_validation_and_features() {
        let (arena, c) = test_env();
        arena
            .validate(&c)
            .expect("classic_meadow.json should pass structural & spawn validation");
        assert_eq!(arena.spawn_points.len(), 8);

        let mut has_grass = false;
        let mut has_stone = false;
        let mut has_water = false;
        let mut has_ice = false;
        let mut has_spring = false;

        for row in &arena.rows {
            for &id in row {
                match TileKind::from_u8(id).unwrap() {
                    TileKind::SolidGrassDirt => has_grass = true,
                    TileKind::SolidStonePlatform => has_stone = true,
                    TileKind::Water => has_water = true,
                    TileKind::Ice => has_ice = true,
                    TileKind::Spring => has_spring = true,
                    TileKind::Empty => {}
                }
            }
        }
        assert!(has_grass && has_stone && has_water && has_ice && has_spring);
    }

    #[test]
    fn horizontal_movement_walls_and_arena_clamping() {
        let (arena, c) = test_env();
        let mutators = Mutators::default();

        // Spawn in open pocket at col 4, row 13 top (x = 65.0, y = 194.0).
        // Running left hits the grass step wall at col 3 row 12 (right edge x = 64.0).
        let mut bunnies = vec![BunnyState::new(0, 65.0, 194.0)];
        bunnies[0].input_bits = InputBits::LEFT;

        for t in 0..30 {
            step_room(&mut bunnies, &arena, &c, &mutators, t);
        }
        assert!(
            (bunnies[0].x - 64.0).abs() < 0.01,
            "expected bunny stopped against col 3 step wall at x=64, got x={}",
            bunnies[0].x
        );
        assert_eq!(bunnies[0].facing, -1);

        // Now test left arena boundary at x = 0.0 on left hill top (y = 146.0)
        bunnies[0] = BunnyState::new(0, 17.0, 146.0);
        bunnies[0].input_bits = InputBits::LEFT;
        for t in 0..20 {
            step_room(&mut bunnies, &arena, &c, &mutators, t);
        }
        assert_eq!(bunnies[0].x, 0.0);
        assert_eq!(bunnies[0].vx, 0.0);

        // Test right arena boundary at x = 400 - 14 = 386.0 on right hill top
        bunnies[0] = BunnyState::new(0, 369.0, 146.0);
        bunnies[0].input_bits = InputBits::RIGHT;
        for t in 0..20 {
            step_room(&mut bunnies, &arena, &c, &mutators, t);
        }
        assert_eq!(bunnies[0].x, c.width - c.bunny_width);
        assert_eq!(bunnies[0].vx, 0.0);
    }

    #[test]
    fn solid_floor_collision_no_tunneling_at_max_fall() {
        let (arena, c) = test_env();
        let mutators = Mutators::default();
        // Drop bunny from near top above the central stone crown (col 12, row 5 at y=80).
        let mut bunnies = vec![BunnyState::new(0, 193.0, 4.0)];
        bunnies[0].vy = c.max_fall_speed;

        for t in 0..45 {
            step_room(&mut bunnies, &arena, &c, &mutators, t);
        }
        assert!(bunnies[0].on_ground);
        assert!(
            (bunnies[0].y - 66.0).abs() < 0.01,
            "bunny should land on row 5 (y=80 -> bunny y=66), got y={}",
            bunnies[0].y
        );
    }

    #[test]
    fn ice_is_more_slippery_than_grass() {
        let (arena, c) = test_env();
        let mutators = Mutators::default();

        // Grass bunny at col 6, row 13 (y=194.0) vs Ice bunny at col 20, row 6 (y=82.0)
        let mut grass = vec![BunnyState::new(0, 97.0, 194.0)];
        let mut ice = vec![BunnyState::new(1, 321.0, 82.0)];

        // Accelerate right for 5 ticks (~166 ms)
        grass[0].input_bits = InputBits::RIGHT;
        ice[0].input_bits = InputBits::RIGHT;
        for t in 0..5 {
            step_room(&mut grass, &arena, &c, &mutators, t);
            step_room(&mut ice, &arena, &c, &mutators, t);
        }
        assert!(grass[0].on_ground && !grass[0].on_ice);
        assert!(ice[0].on_ground && ice[0].on_ice);

        // Give both identical cruise speed then release input to measure slide distance.
        grass[0].vx = c.max_run_speed;
        ice[0].vx = c.max_run_speed;
        grass[0].input_bits = 0;
        ice[0].input_bits = 0;
        let grass_start = grass[0].x;
        let ice_start = ice[0].x;

        for t in 5..30 {
            step_room(&mut grass, &arena, &c, &mutators, t);
            step_room(&mut ice, &arena, &c, &mutators, t);
        }
        let grass_slide = grass[0].x - grass_start;
        let ice_slide = ice[0].x - ice_start;
        assert!(
            ice_slide > grass_slide * 3.0,
            "ice slide ({ice_slide}) should be much greater than grass slide ({grass_slide})"
        );
    }

    #[test]
    fn water_buoyancy_splash_and_swim_out() {
        let (arena, c) = test_env();
        let mutators = Mutators::default();

        // Drop bunny above the central pond (col 12, x = 193.0, y = 180.0; pond starts at row 13 y=208)
        let mut bunnies = vec![BunnyState::new(0, 193.0, 180.0)];
        let mut saw_splash = false;
        for t in 0..25 {
            let events = step_room(&mut bunnies, &arena, &c, &mutators, t);
            if events
                .iter()
                .any(|e| matches!(e, StepEvent::WaterSplash { slot: 0, .. }))
            {
                saw_splash = true;
            }
        }
        assert!(saw_splash, "entering pond should emit WaterSplash");
        assert!(bunnies[0].in_water);
        assert!(
            bunnies[0].vy <= c.water_max_fall + 0.01,
            "sinking speed {} should be capped at water_max_fall {}",
            bunnies[0].vy,
            c.water_max_fall
        );

        // Hold JUMP to swim upward out of the pond
        bunnies[0].input_bits = InputBits::JUMP;
        let mut exited_water = false;
        for t in 25..60 {
            step_room(&mut bunnies, &arena, &c, &mutators, t);
            if !bunnies[0].in_water && bunnies[0].y < 194.0 {
                exited_water = true;
                break;
            }
        }
        assert!(exited_water, "holding jump in water should swim out above y=194");
    }

    #[test]
    fn spring_launches_bunny_high() {
        let (arena, c) = test_env();
        let mutators = Mutators::default();

        // Spring tile at col 5, row 12 (x = 80..96, top y = 192 -> bunny rests at y = 178)
        let mut bunnies = vec![BunnyState::new(0, 81.0, 177.0)];
        let mut saw_sprung = false;
        let mut min_y = bunnies[0].y;

        for t in 0..35 {
            let events = step_room(&mut bunnies, &arena, &c, &mutators, t);
            if events
                .iter()
                .any(|e| matches!(e, StepEvent::Sprung { slot: 0, .. }))
            {
                saw_sprung = true;
            }
            min_y = min_y.min(bunnies[0].y);
        }

        assert!(saw_sprung, "landing on spring tile should emit Sprung");
        assert!(
            min_y < 82.0,
            "spring should launch bunny high enough to reach upper Row 6 ledges (y<82), reached min_y={min_y}"
        );
    }

    #[test]
    fn head_stomp_kills_victim_and_rebounds_killer() {
        let (arena, c) = test_env();
        let mutators = Mutators::default();

        // Victim standing at col 6, row 13 (x = 97.0, y = 194.0)
        // Killer descending from above at x = 97.0, y = 182.0, vy = 120.0
        let mut bunnies = vec![
            BunnyState::new(0, 97.0, 182.0),
            BunnyState::new(1, 97.0, 194.0),
        ];
        bunnies[0].vy = 120.0;

        let mut killed_event = None;
        for t in 0..5 {
            let events = step_room(&mut bunnies, &arena, &c, &mutators, t);
            for ev in events {
                if let StepEvent::Killed { .. } = ev {
                    killed_event = Some(ev);
                }
            }
            if killed_event.is_some() {
                break;
            }
        }

        match killed_event {
            Some(StepEvent::Killed {
                killer_slot,
                victim_slot,
                ..
            }) => {
                assert_eq!(killer_slot, 0);
                assert_eq!(victim_slot, 1);
            }
            other => panic!("expected Killed event, got {other:?}"),
        }
        assert!(bunnies[0].alive);
        assert!(bunnies[0].vy < 0.0, "killer should rebound upward");
        assert!(!bunnies[1].alive);
        assert_eq!(bunnies[1].respawn_ticks, c.respawn_ticks);
    }

    #[test]
    fn invulnerable_bunny_cannot_be_stomped() {
        let (arena, c) = test_env();
        let mutators = Mutators::default();

        let mut bunnies = vec![
            BunnyState::new(0, 97.0, 182.0),
            BunnyState::new(1, 97.0, 194.0),
        ];
        bunnies[0].vy = 120.0;
        bunnies[1].invuln_ticks = 10;

        for t in 0..5 {
            let events = step_room(&mut bunnies, &arena, &c, &mutators, t);
            assert!(
                !events.iter().any(|e| matches!(e, StepEvent::Killed { .. })),
                "invulnerable bunny must not be stomped"
            );
        }
        assert!(bunnies[1].alive);
    }

    #[test]
    fn side_bump_separates_without_killing() {
        let (arena, c) = test_env();
        let mutators = Mutators::default();

        // Two bunnies standing side-by-side at same y=194.0, running into each other
        let mut bunnies = vec![
            BunnyState::new(0, 90.0, 194.0),
            BunnyState::new(1, 102.0, 194.0),
        ];
        bunnies[0].input_bits = InputBits::RIGHT;
        bunnies[1].input_bits = InputBits::LEFT;

        for t in 0..10 {
            let events = step_room(&mut bunnies, &arena, &c, &mutators, t);
            assert!(
                !events.iter().any(|e| matches!(e, StepEvent::Killed { .. })),
                "horizontal bump must not kill"
            );
        }
        assert!(bunnies[0].alive && bunnies[1].alive);
        assert!(
            bunnies[1].x >= bunnies[0].x + c.bunny_width - 0.1,
            "bunnies should stay separated horizontally: x0={}, x1={}",
            bunnies[0].x,
            bunnies[1].x
        );
    }

    #[test]
    fn respawn_countdown_and_safest_spawn_selection() {
        let (arena, c) = test_env();
        let mutators = Mutators::default();

        // Alive opponent standing near left spawn (17, 146).
        // Dead bunny has 2 ticks left to respawn.
        let mut bunnies = vec![
            BunnyState::new(0, 17.0, 146.0),
            BunnyState::new(1, 17.0, 146.0),
        ];
        bunnies[1].alive = false;
        bunnies[1].respawn_ticks = 2;

        let ev0 = step_room(&mut bunnies, &arena, &c, &mutators, 0);
        assert!(!bunnies[1].alive);
        assert_eq!(bunnies[1].respawn_ticks, 1);
        assert!(ev0.is_empty());

        let ev1 = step_room(&mut bunnies, &arena, &c, &mutators, 1);
        assert!(bunnies[1].alive);
        assert_eq!(bunnies[1].invuln_ticks, c.spawn_invuln_ticks);
        assert!(ev1
            .iter()
            .any(|e| matches!(e, StepEvent::Respawned { slot: 1, .. })));

        // Chosen spawn should be far from alive bunny at (17, 146) — specifically right side (369, 146).
        let dist_sq = (bunnies[1].x - bunnies[0].x).powi(2) + (bunnies[1].y - bunnies[0].y).powi(2);
        assert!(
            dist_sq > 200.0_f32.powi(2),
            "respawn ({}, {}) should maximize distance from opponent at ({}, {})",
            bunnies[1].x,
            bunnies[1].y,
            bunnies[0].x,
            bunnies[0].y
        );
    }

    #[test]
    fn mutators_low_gravity_pogo_and_jetpack() {
        let (arena, c) = test_env();

        // 1. Low gravity jumps higher than normal gravity (col 0, x=1.0, y=146.0 has clear sky overhead)
        let mut normal_b = vec![BunnyState::new(0, 1.0, 146.0)];
        normal_b[0].input_bits = InputBits::JUMP;
        let mut low_g_b = vec![BunnyState::new(0, 1.0, 146.0)];
        low_g_b[0].input_bits = InputBits::JUMP;

        let mut normal_min_y = 146.0_f32;
        let mut low_g_min_y = 146.0_f32;
        let low_g_mut = Mutators {
            low_gravity: true,
            ..Default::default()
        };

        for t in 0..35 {
            step_room(&mut normal_b, &arena, &c, &Mutators::default(), t);
            step_room(&mut low_g_b, &arena, &c, &low_g_mut, t);
            normal_min_y = normal_min_y.min(normal_b[0].y);
            low_g_min_y = low_g_min_y.min(low_g_b[0].y);
        }
        assert!(
            low_g_min_y < normal_min_y - 20.0,
            "low_gravity peak ({low_g_min_y}) should be much higher than normal ({normal_min_y})"
        );

        // 2. Pogo auto-jumps on ground with zero input_bits
        let mut pogo_b = vec![BunnyState::new(0, 97.0, 194.0)];
        let pogo_mut = Mutators {
            pogo: true,
            ..Default::default()
        };
        let mut jump_count = 0;
        for t in 0..70 {
            let events = step_room(&mut pogo_b, &arena, &c, &pogo_mut, t);
            if events
                .iter()
                .any(|e| matches!(e, StepEvent::Jumped { slot: 0 }))
            {
                jump_count += 1;
            }
        }
        assert!(
            jump_count >= 2,
            "pogo mutator should auto-jump repeatedly on landing, saw {jump_count} jumps"
        );

        // 3. Jetpack climbs continuously in mid-air while JUMP is held (col 0 has clear sky)
        let mut jet_b = vec![BunnyState::new(0, 1.0, 140.0)];
        jet_b[0].input_bits = InputBits::JUMP;
        let jet_mut = Mutators {
            jetpack: true,
            ..Default::default()
        };
        for t in 0..20 {
            step_room(&mut jet_b, &arena, &c, &jet_mut, t);
        }
        assert!(
            jet_b[0].y < 110.0 && jet_b[0].vy < 0.0,
            "jetpack should lift bunny upward in mid-air, y={}, vy={}",
            jet_b[0].y,
            jet_b[0].vy
        );
    }

    #[test]
    fn dead_bunny_ignores_environment_and_collisions() {
        let (arena, c) = test_env();
        let mutators = Mutators::default();

        // Dead bunny over spring, dead bunny in water, dead bunny overlapping alive bunny
        let mut dead_spring = BunnyState::new(0, 81.0, 178.0);
        dead_spring.alive = false;
        dead_spring.respawn_ticks = 10;

        let mut dead_water = BunnyState::new(1, 193.0, 212.0);
        dead_water.alive = false;
        dead_water.respawn_ticks = 10;

        let mut dead_overlap_above = BunnyState::new(2, 97.0, 182.0);
        dead_overlap_above.alive = false;
        dead_overlap_above.respawn_ticks = 10;
        dead_overlap_above.vy = 120.0;

        let alive = BunnyState::new(3, 97.0, 194.0);
        let mut bunnies = vec![dead_spring, dead_water, dead_overlap_above, alive];

        let events = step_room(&mut bunnies, &arena, &c, &mutators, 0);
        assert!(
            events.is_empty(),
            "dead bunnies should emit no Sprung/WaterSplash/Killed events, got {events:?}"
        );
        assert_eq!(bunnies[0].vy, 0.0);
        assert!(bunnies[3].alive);
        assert_eq!(bunnies[3].x, 97.0);
        assert_eq!(bunnies[3].vx, 0.0);

        // Also test side-by-side dead vs alive overlap produces zero separation
        let mut dead_side = BunnyState::new(0, 99.0, 194.0);
        dead_side.alive = false;
        dead_side.respawn_ticks = 10;
        let alive_side = BunnyState::new(1, 97.0, 194.0);
        let mut side_bunnies = vec![dead_side, alive_side];
        let side_events = step_room(&mut side_bunnies, &arena, &c, &mutators, 1);
        assert!(side_events.is_empty());
        assert_eq!(side_bunnies[1].x, 97.0);
        assert_eq!(side_bunnies[1].vx, 0.0);
    }

    #[test]
    fn single_tick_double_stomp_kills_both_and_preserves_horizontal_momentum() {
        let (arena, c) = test_env();
        let mutators = Mutators::default();

        // Killer descends onto two adjacent non-overlapping victims on clear grass (cols 6..7: x=96..128).
        let mut killer = BunnyState::new(0, 105.0, 182.0);
        killer.vx = 60.0;
        killer.vy = 120.0;
        killer.input_bits = InputBits::RIGHT;

        let v1 = BunnyState::new(1, 97.0, 194.0);
        let v2 = BunnyState::new(2, 113.0, 194.0);
        let mut bunnies = vec![killer, v1, v2];

        let events = step_room(&mut bunnies, &arena, &c, &mutators, 0);

        assert!(bunnies[0].alive, "killer must survive double-stomp");
        assert!(
            bunnies[0].vy < -150.0,
            "killer should rebound upward once, vy={}",
            bunnies[0].vy
        );
        assert!(
            bunnies[0].vx > 50.0 && bunnies[0].x > 105.0,
            "killer must not be side-bumped or have vx zeroed: x={}, vx={}",
            bunnies[0].x,
            bunnies[0].vx
        );
        assert!(!bunnies[1].alive, "victim 1 should be killed");
        assert!(!bunnies[2].alive, "victim 2 should be killed");

        let kills: Vec<(u8, u8)> = events
            .iter()
            .filter_map(|e| match e {
                StepEvent::Killed {
                    killer_slot,
                    victim_slot,
                    ..
                } => Some((*killer_slot, *victim_slot)),
                _ => None,
            })
            .collect();
        assert_eq!(kills, vec![(0, 1), (0, 2)]);
    }

    #[test]
    fn three_bunny_stack_is_order_independent() {
        let (arena, c) = test_env();
        let mutators = Mutators::default();

        let make_a = || {
            let mut a = BunnyState::new(0, 97.0, 170.0);
            a.vy = 120.0;
            a
        };
        let make_b = || {
            let mut b = BunnyState::new(1, 97.0, 182.0);
            b.vy = 120.0;
            b
        };
        let make_c = || BunnyState::new(2, 97.0, 194.0);

        let mut abc = vec![make_a(), make_b(), make_c()];
        let mut cba = vec![make_c(), make_b(), make_a()];

        let ev_abc = step_room(&mut abc, &arena, &c, &mutators, 0);
        let ev_cba = step_room(&mut cba, &arena, &c, &mutators, 0);

        assert_eq!(ev_abc, ev_cba, "events must be independent of slice order");

        abc.sort_by_key(|b| b.slot);
        cba.sort_by_key(|b| b.slot);
        assert_eq!(abc, cba, "final states must be independent of slice order");

        assert!(abc[0].alive && abc[0].vy < 0.0);
        assert!(!abc[1].alive);
        assert!(!abc[2].alive);
    }

    #[test]
    fn prev_jump_edge_trigger_invariants() {
        let (arena, c) = test_env();
        let mutators = Mutators::default();

        // 1. Holding JUMP continuously across landing does not auto-jump in normal mode.
        let mut b = vec![BunnyState::new(0, 1.0, 146.0)];
        b[0].input_bits = InputBits::JUMP;

        let mut jump_events = 0;
        let mut saw_airborne = false;
        let mut landed_again = false;

        for t in 0..60 {
            let events = step_room(&mut b, &arena, &c, &mutators, t);
            jump_events += events
                .iter()
                .filter(|e| matches!(e, StepEvent::Jumped { slot: 0 }))
                .count();
            if !b[0].on_ground {
                saw_airborne = true;
            } else if saw_airborne {
                landed_again = true;
            }
        }
        assert!(landed_again, "bunny should have jumped and landed within 60 ticks");
        assert_eq!(
            jump_events, 1,
            "holding JUMP across landing must only emit 1 jump event"
        );

        // 2. Holding JUMP across respawn does not auto-jump on the respawn tick.
        let mut dead = BunnyState::new(0, 1.0, 146.0);
        dead.alive = false;
        dead.respawn_ticks = 2;
        dead.input_bits = InputBits::JUMP;
        dead.prev_jump = false;
        let mut respawning = vec![dead];

        let ev0 = step_room(&mut respawning, &arena, &c, &mutators, 0);
        assert!(ev0.is_empty());

        let ev1 = step_room(&mut respawning, &arena, &c, &mutators, 1);
        assert!(respawning[0].alive);
        assert!(ev1
            .iter()
            .any(|e| matches!(e, StepEvent::Respawned { slot: 0, .. })));
        assert!(
            !ev1.iter().any(|e| matches!(e, StepEvent::Jumped { slot: 0 })),
            "holding JUMP across respawn must not jump on respawn tick"
        );

        let ev2 = step_room(&mut respawning, &arena, &c, &mutators, 2);
        assert!(
            !ev2.iter().any(|e| matches!(e, StepEvent::Jumped { slot: 0 })),
            "still holding JUMP after respawn must not trigger a jump"
        );
    }

    #[test]
    fn jetpack_does_not_clamp_faster_upward_velocities() {
        let (arena, c) = test_env();
        let jet_mut = Mutators {
            jetpack: true,
            ..Default::default()
        };

        // 1. Falling onto a spring while holding JUMP with jetpack keeps vy faster than jetpack_max_rise.
        let mut spring_b = vec![BunnyState::new(0, 81.0, 176.5)];
        spring_b[0].vy = 150.0;
        spring_b[0].input_bits = InputBits::JUMP;
        let events = step_room(&mut spring_b, &arena, &c, &jet_mut, 0);
        assert!(events
            .iter()
            .any(|e| matches!(e, StepEvent::Sprung { slot: 0, .. })));
        assert!(
            spring_b[0].vy < -250.0,
            "jetpack must not clamp spring upward velocity ({}) down to jetpack_max_rise ({})",
            spring_b[0].vy,
            c.jetpack_max_rise
        );

        // 2. Normal jump while holding JUMP with jetpack keeps vy faster than jetpack_max_rise.
        let mut jump_b = vec![BunnyState::new(0, 1.0, 146.0)];
        jump_b[0].input_bits = InputBits::JUMP;
        let j_events = step_room(&mut jump_b, &arena, &c, &jet_mut, 0);
        assert!(j_events
            .iter()
            .any(|e| matches!(e, StepEvent::Jumped { slot: 0 })));
        assert!(
            jump_b[0].vy < c.jetpack_max_rise,
            "jetpack must not clamp ground jump upward velocity ({}) down to jetpack_max_rise ({})",
            jump_b[0].vy,
            c.jetpack_max_rise
        );
    }
}
