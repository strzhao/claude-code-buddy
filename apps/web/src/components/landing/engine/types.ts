export interface Vec2 {
  x: number;
  y: number;
}

export type CatState = "idle" | "walk" | "eat" | "scared" | "permissionRequest" | "taskComplete";

export type IdleSubState = "idle-a" | "idle-b" | "clean" | "sleep";

export type AnimationName =
  | "idle-a"
  | "idle-b"
  | "walk-a"
  | "walk-b"
  | "clean"
  | "sleep"
  | "jump"
  | "paw"
  | "scared";

// Frame counts for each animation
export const FRAME_COUNTS: Record<AnimationName, number> = {
  "idle-a": 8,
  "idle-b": 7,
  "walk-a": 8,
  "walk-b": 8,
  clean: 6,
  sleep: 4,
  jump: 4,
  paw: 4,
  scared: 4,
};

export const PHYSICS = {
  walkSpeed: 40, // px/s
  gravity: 800, // px/s² (for food)
  catMinDistance: 52, // px
  separationNudge: 0.5, // px per frame
  maxFoods: 3,
  foodCooldown: 500, // ms
  animFps: 8, // idle/walk frame rate
  actionFps: 6.67, // paw/scared frame rate (150ms/frame)
  scareRadius: 80, // px
  lookRadius: 9999, // px — let cats see food anywhere on canvas
  eatDistance: 8, // px
  idleMinTime: 2000, // ms
  idleMaxTime: 5000, // ms
} as const;
