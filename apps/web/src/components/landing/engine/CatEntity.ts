import { AnimatedSprite, Container, Graphics, Text, type Texture } from "pixi.js";
import type { SpriteFrameMap } from "./SpriteLoader";
import type { Vec2, CatState } from "./types";
import { PHYSICS } from "./types";
import type { FoodEntity } from "./FoodEntity";

const ANIM_SPEED_IDLE = PHYSICS.animFps / 60;
const ANIM_SPEED_ACTION = PHYSICS.actionFps / 60;

export class CatEntity {
  /** The outer container (holds sprite + overlays). Add THIS to the stage. */
  container: Container;
  sprite: AnimatedSprite;
  state: CatState = "idle";

  private frames: SpriteFrameMap;
  private facingLeft = false;
  targetFood: FoodEntity | null = null;
  private idleTimer = 0;
  private idleTimeout = 0;
  private previousState: CatState = "idle";
  private currentIdleAnim = "idle-a";

  // Permission request visuals
  private permTimer = 0;
  private shakePhase = 0;
  private alertOverlay: Container | null = null;

  // Task complete
  private taskCompleteTimer = 0;
  private taskCompleteTarget = 0; // x position to walk to
  private taskReachedBed = false;

  // Original position (to return after taskComplete)
  private homeX = 0;
  private canvasWidth = 0;

  constructor(frames: SpriteFrameMap, x: number, groundY: number, canvasWidth: number) {
    this.frames = frames;
    this.homeX = x;
    this.canvasWidth = canvasWidth;

    this.container = new Container();
    this.container.x = x;
    this.container.y = groundY;

    this.sprite = new AnimatedSprite(frames["idle-a"]);
    this.sprite.anchor.set(0.5, 1);
    this.sprite.scale.set(2);
    this.container.addChild(this.sprite);

    this.sprite.animationSpeed = ANIM_SPEED_IDLE;
    this.sprite.loop = true;
    this.sprite.play();

    this._resetIdleTimeout();
  }

  get x() {
    return this.container.x;
  }
  set x(v: number) {
    this.container.x = v;
  }
  get y() {
    return this.container.y;
  }
  set y(v: number) {
    this.container.y = v;
  }

  update(dt: number, foods: FoodEntity[], otherCats: CatEntity[], mousePos: Vec2 | null) {
    // Mouse scare — only in idle/walk states
    if (
      mousePos !== null &&
      this.state !== "scared" &&
      this.state !== "permissionRequest" &&
      this.state !== "taskComplete"
    ) {
      const dx = mousePos.x - this.x;
      const dy = mousePos.y - this.y;
      const dist = Math.sqrt(dx * dx + dy * dy);
      if (dist < PHYSICS.scareRadius) {
        this._transitionToScared();
        return;
      }
    }

    switch (this.state) {
      case "idle":
        this._updateIdle(dt, foods);
        break;
      case "walk":
        this._updateWalk(dt);
        break;
      case "eat":
        break; // onComplete callback handles transition
      case "scared":
        break; // onComplete callback handles transition
      case "permissionRequest":
        this._updatePermissionRequest(dt);
        break;
      case "taskComplete":
        this._updateTaskComplete(dt);
        break;
    }

    // No separation during taskComplete (cat is at edge)
    if (this.state !== "taskComplete") {
      this._applySeparation(otherCats);
    }
  }

  // --- Public triggers (called by SceneEngine demo cycle) ---

  triggerPermissionRequest() {
    if (this.state === "permissionRequest" || this.state === "taskComplete") return;
    this.previousState = this.state;
    this.state = "permissionRequest";
    this.permTimer = 0;
    this.shakePhase = 0;

    // Play scared animation looping (like macOS app)
    this._playAnimation("scared", true);

    // Tint red
    this.sprite.tint = 0xff4d00;

    // Add alert overlay: "!" badge + "Permission?" label
    this._showAlertOverlay();
  }

  triggerTaskComplete() {
    if (this.state === "taskComplete" || this.state === "permissionRequest") return;
    this.previousState = this.state;
    this.state = "taskComplete";
    this.taskCompleteTimer = 0;
    this.taskReachedBed = false;

    // Walk target: right edge of canvas
    this.taskCompleteTarget = this.canvasWidth - 60;

    // Start walk animation toward bed
    const walkAnim = Math.random() < 0.5 ? "walk-a" : "walk-b";
    this._playAnimation(walkAnim, true);
    this._lookAt(this.taskCompleteTarget);
  }

  // --- Permission Request ---

  private _updatePermissionRequest(dt: number) {
    this.permTimer += dt * 1000;

    // Horizontal shake
    this.shakePhase += dt * 30;
    this.sprite.x = Math.sin(this.shakePhase) * 3; // shake ±3px relative to container

    // Pulse the alert overlay
    if (this.alertOverlay) {
      this.alertOverlay.alpha = 0.7 + 0.3 * Math.sin(this.permTimer * 0.006);
    }

    // After 3 seconds, exit
    if (this.permTimer >= 3000) {
      this._exitPermissionRequest();
    }
  }

  private _showAlertOverlay() {
    this._removeAlertOverlay();

    this.alertOverlay = new Container();

    // "!" badge — red circle with white "!"
    const badge = new Graphics();
    badge.circle(0, 0, 10);
    badge.fill(0xff3333);
    this.alertOverlay.addChild(badge);

    const exclamation = new Text({
      text: "!",
      style: { fontSize: 14, fontWeight: "bold", fill: 0xffffff, fontFamily: "monospace" },
    });
    exclamation.anchor.set(0.5, 0.5);
    this.alertOverlay.addChild(exclamation);

    // "Permission?" label
    const label = new Text({
      text: "Permission?",
      style: { fontSize: 10, fill: 0xff4d00, fontFamily: "monospace", fontWeight: "bold" },
    });
    label.anchor.set(0.5, 0);
    label.y = 14;
    this.alertOverlay.addChild(label);

    // Position above the cat
    this.alertOverlay.x = 0;
    this.alertOverlay.y = -105;

    this.container.addChild(this.alertOverlay);
  }

  private _removeAlertOverlay() {
    if (this.alertOverlay) {
      this.container.removeChild(this.alertOverlay);
      this.alertOverlay.destroy({ children: true });
      this.alertOverlay = null;
    }
  }

  private _exitPermissionRequest() {
    this._removeAlertOverlay();
    this.sprite.tint = 0xffffff; // remove red tint
    this.sprite.x = 0; // reset shake offset
    this._returnToIdle();
  }

  // --- Task Complete ---

  private _updateTaskComplete(dt: number) {
    if (!this.taskReachedBed) {
      // Walk toward bed position
      const dx = this.taskCompleteTarget - this.x;
      const dist = Math.abs(dx);

      if (dist <= PHYSICS.eatDistance) {
        // Arrived at bed
        this.taskReachedBed = true;
        this.taskCompleteTimer = 0;

        // Switch to sleep animation
        this._playAnimation("sleep", true);

        // Show "Done ✓" label
        this._showTaskLabel();
      } else {
        const direction = dx > 0 ? 1 : -1;
        this.x += direction * PHYSICS.walkSpeed * dt;
        this._lookAt(this.taskCompleteTarget);
      }
    } else {
      // Sleeping at bed
      this.taskCompleteTimer += dt * 1000;

      // After 5 seconds, walk back home
      if (this.taskCompleteTimer >= 5000) {
        this._exitTaskComplete();
      }
    }
  }

  private _showTaskLabel() {
    this._removeAlertOverlay();

    this.alertOverlay = new Container();

    const bg = new Graphics();
    bg.roundRect(-32, -10, 64, 20, 4);
    bg.fill({ color: 0x2d8659, alpha: 0.9 });
    this.alertOverlay.addChild(bg);

    const label = new Text({
      text: "Done ✓",
      style: { fontSize: 11, fill: 0xffffff, fontFamily: "monospace", fontWeight: "bold" },
    });
    label.anchor.set(0.5, 0.5);
    this.alertOverlay.addChild(label);

    this.alertOverlay.x = 0;
    this.alertOverlay.y = -105;

    this.container.addChild(this.alertOverlay);
  }

  private _exitTaskComplete() {
    this._removeAlertOverlay();
    this.state = "walk";
    this.taskReachedBed = false;

    // Walk back to home position
    this.targetFood = null; // reuse walk state manually

    const walkAnim = Math.random() < 0.5 ? "walk-a" : "walk-b";
    this._playAnimation(walkAnim, true);
    this._lookAt(this.homeX);

    // Override walk: we set a special "walk home" state via _returnHome flag
    this._walkingHome = true;
  }

  private _walkingHome = false;

  // --- Idle ---

  private _updateIdle(dt: number, foods: FoodEntity[]) {
    this.idleTimer += dt * 1000;

    if (this.idleTimer >= this.idleTimeout) {
      this.idleTimer = 0;
      this._pickNextIdleSubState();
    }

    // Check for nearby food
    const food = this._findNearestLandedFood(foods);
    if (food) {
      food.markClaimed();
      this.targetFood = food;
      this.state = "walk";
      this._walkingHome = false;
      const walkAnim = Math.random() < 0.5 ? "walk-a" : "walk-b";
      this._playAnimation(walkAnim, true);
    }
  }

  // --- Walk ---

  private _updateWalk(dt: number) {
    if (this._walkingHome) {
      // Walking back to home position after task complete
      const dx = this.homeX - this.x;
      const dist = Math.abs(dx);
      this._lookAt(this.homeX);

      if (dist <= PHYSICS.eatDistance) {
        this._walkingHome = false;
        this._returnToIdle();
      } else {
        const direction = dx > 0 ? 1 : -1;
        this.x += direction * PHYSICS.walkSpeed * dt;
      }
      return;
    }

    if (!this.targetFood) {
      this._returnToIdle();
      return;
    }

    if (this.targetFood.state === "eaten") {
      this.targetFood = null;
      this._returnToIdle();
      return;
    }

    const targetX = this.targetFood.sprite.x;
    const dx = targetX - this.x;
    const dist = Math.abs(dx);

    this._lookAt(targetX);

    if (dist <= PHYSICS.eatDistance) {
      this.state = "eat";
      this._playAnimation("paw", false, () => {
        if (this.targetFood) {
          this.targetFood.markEaten();
        }
        this.targetFood = null;
        this._returnToIdle();
      });
    } else {
      const direction = dx > 0 ? 1 : -1;
      this.x += direction * PHYSICS.walkSpeed * dt;
    }
  }

  // --- Scared ---

  private _transitionToScared() {
    this.previousState = this.state === "scared" ? this.previousState : this.state;
    this.state = "scared";
    this._playAnimation("scared", false, () => {
      this.state = this.previousState;
      if (this.previousState === "idle") {
        this._playAnimation(this.currentIdleAnim as "idle-a", true);
        this._resetIdleTimeout();
      } else if (this.previousState === "walk") {
        const walkAnim = Math.random() < 0.5 ? "walk-a" : "walk-b";
        this._playAnimation(walkAnim, true);
      }
    });
  }

  // --- Idle sub-states ---

  private _pickNextIdleSubState() {
    if (this.currentIdleAnim === "idle-a") {
      const roll = Math.random();
      if (roll < 0.4) {
        this.currentIdleAnim = "idle-b";
        this._playAnimation("idle-b", false, () => {
          this.currentIdleAnim = "idle-a";
          this._playAnimation("idle-a", true);
          this._resetIdleTimeout();
        });
      } else if (roll < 0.7) {
        this.currentIdleAnim = "clean";
        this._playAnimation("clean", false, () => {
          this.currentIdleAnim = "idle-a";
          this._playAnimation("idle-a", true);
          this._resetIdleTimeout();
        });
      } else {
        this.currentIdleAnim = "sleep";
        this._playAnimation("sleep", false, () => {
          this.currentIdleAnim = "idle-a";
          this._playAnimation("idle-a", true);
          this._resetIdleTimeout();
        });
      }
    } else {
      this._resetIdleTimeout();
    }
  }

  private _resetIdleTimeout() {
    this.idleTimer = 0;
    this.idleTimeout =
      PHYSICS.idleMinTime + Math.random() * (PHYSICS.idleMaxTime - PHYSICS.idleMinTime);
  }

  private _returnToIdle() {
    this.state = "idle";
    this.currentIdleAnim = "idle-a";
    this._playAnimation("idle-a", true);
    this._resetIdleTimeout();
  }

  private _findNearestLandedFood(foods: FoodEntity[]): FoodEntity | null {
    let nearest: FoodEntity | null = null;
    let nearestDist: number = PHYSICS.lookRadius;

    for (const food of foods) {
      if (food.state !== "landed") continue;
      const dist = Math.abs(food.sprite.x - this.x);
      if (dist < nearestDist) {
        nearestDist = dist;
        nearest = food;
      }
    }
    return nearest;
  }

  // --- Animation helpers ---

  private _playAnimation(name: string, loop: boolean, onComplete?: () => void) {
    const textures = this.frames[name as keyof SpriteFrameMap];
    if (!textures || textures.length === 0) return;

    this.sprite.stop();
    this.sprite.textures = textures as Texture[];

    const isAction = name === "paw" || name === "scared" || name === "jump";
    this.sprite.animationSpeed = isAction ? ANIM_SPEED_ACTION : ANIM_SPEED_IDLE;

    this.sprite.loop = loop;
    this.sprite.onComplete = onComplete ?? undefined;
    this.sprite.currentFrame = 0;
    this.sprite.play();
  }

  private _lookAt(targetX: number) {
    const dx = targetX - this.x;
    if (dx < 0 && !this.facingLeft) {
      this.facingLeft = true;
      this.sprite.scale.x = -Math.abs(this.sprite.scale.x);
    } else if (dx > 0 && this.facingLeft) {
      this.facingLeft = false;
      this.sprite.scale.x = Math.abs(this.sprite.scale.x);
    }
  }

  private _applySeparation(otherCats: CatEntity[]) {
    for (const other of otherCats) {
      const dx = this.x - other.x;
      const dist = Math.abs(dx);
      if (dist < PHYSICS.catMinDistance && dist > 0) {
        this.x += PHYSICS.separationNudge * (dx > 0 ? 1 : -1);
      } else if (dist === 0) {
        this.x += PHYSICS.separationNudge * (Math.random() < 0.5 ? 1 : -1);
      }
    }
  }
}
