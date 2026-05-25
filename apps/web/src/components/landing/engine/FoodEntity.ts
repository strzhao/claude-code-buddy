// Represents a food item that falls from the sky
// States: 'falling' | 'landed' | 'claimed' | 'eaten'
// Physics: gravity acceleration, stops at groundY
// When eaten: fade out (alpha 0 over 300ms) then mark for removal

import { Sprite, type Texture } from "pixi.js";
import { PHYSICS } from "./types";

export type FoodState = "falling" | "landed" | "claimed" | "eaten";

const FADE_DURATION = 300; // ms

export class FoodEntity {
  sprite: Sprite;
  state: FoodState = "falling";
  vy = 0;
  private fadeTimer = 0;

  constructor(texture: Texture, x: number, startY: number) {
    this.sprite = new Sprite(texture);
    // Food sprites are 32x32 displayed at 2x = 64px
    this.sprite.scale.set(2);
    // Anchor at bottom-center so the food "lands" at groundY
    this.sprite.anchor.set(0.5, 1);
    this.sprite.x = x;
    this.sprite.y = startY;
  }

  /**
   * Update food physics and state.
   * @param dt - Delta time in seconds
   * @param groundY - The y coordinate of the ground
   * @returns false when the entity should be removed from the scene
   */
  update(dt: number, groundY: number): boolean {
    if (this.state === "falling") {
      this.vy += PHYSICS.gravity * dt;
      this.sprite.y += this.vy * dt;

      if (this.sprite.y >= groundY) {
        this.sprite.y = groundY;
        this.vy = 0;
        this.state = "landed";
      }
    } else if (this.state === "eaten") {
      this.fadeTimer += dt * 1000; // convert to ms
      const progress = Math.min(this.fadeTimer / FADE_DURATION, 1);
      this.sprite.alpha = 1 - progress;

      if (progress >= 1) {
        return false; // signal removal
      }
    }

    return true;
  }

  markClaimed() {
    this.state = "claimed";
  }

  markEaten() {
    this.state = "eaten";
    this.fadeTimer = 0;
  }

  destroy() {
    this.sprite.destroy();
  }
}
