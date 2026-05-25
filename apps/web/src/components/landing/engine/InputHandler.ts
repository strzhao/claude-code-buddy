// Manages canvas input events
// Click → create food at click position (with cooldown)
// Mouse move → track position for cat proximity

import type { Vec2 } from "./types";
import { PHYSICS } from "./types";

export class InputHandler {
  mousePos: Vec2 | null = null;
  private lastFoodTime = 0;
  private onFoodDrop: ((x: number) => void) | null = null;
  private canvas: HTMLCanvasElement | null = null;

  private _handleClick = (e: MouseEvent) => {
    const now = Date.now();
    if (now - this.lastFoodTime < PHYSICS.foodCooldown) return;
    this.lastFoodTime = now;

    if (!this.canvas || !this.onFoodDrop) return;
    const rect = this.canvas.getBoundingClientRect();
    const scaleX = this.canvas.width / rect.width;
    const x = (e.clientX - rect.left) * scaleX;
    this.onFoodDrop(x);
  };

  private _handleMouseMove = (e: MouseEvent) => {
    if (!this.canvas) return;
    const rect = this.canvas.getBoundingClientRect();
    const scaleX = this.canvas.width / rect.width;
    const scaleY = this.canvas.height / rect.height;
    this.mousePos = {
      x: (e.clientX - rect.left) * scaleX,
      y: (e.clientY - rect.top) * scaleY,
    };
  };

  private _handleMouseLeave = () => {
    this.mousePos = null;
  };

  attach(canvas: HTMLCanvasElement, onFoodDrop: (x: number) => void) {
    this.canvas = canvas;
    this.onFoodDrop = onFoodDrop;

    canvas.addEventListener("click", this._handleClick);
    canvas.addEventListener("mousemove", this._handleMouseMove);
    canvas.addEventListener("mouseleave", this._handleMouseLeave);
  }

  detach() {
    if (!this.canvas) return;
    this.canvas.removeEventListener("click", this._handleClick);
    this.canvas.removeEventListener("mousemove", this._handleMouseMove);
    this.canvas.removeEventListener("mouseleave", this._handleMouseLeave);
    this.canvas = null;
    this.onFoodDrop = null;
    this.mousePos = null;
  }
}
