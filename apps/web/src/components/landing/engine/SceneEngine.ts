import { Application, Container } from "pixi.js";
import { loadCatSprites, loadFoodSprites } from "./SpriteLoader";
import { CatEntity } from "./CatEntity";
import { FoodEntity } from "./FoodEntity";
import { InputHandler } from "./InputHandler";
import { PHYSICS } from "./types";
import type { Texture } from "pixi.js";

export class SceneEngine {
  private app: Application | null = null;
  private cats: CatEntity[] = [];
  private foods: FoodEntity[] = [];
  private foodTextures: Texture[] = [];
  private input = new InputHandler();
  private gameContainer = new Container();
  private groundY = 0;
  private width = 0;

  // Demo cycle timers
  private permissionTimer = 0;
  private permissionInterval = 0;
  private taskCompleteTimer = 0;
  private taskCompleteInterval = 0;

  async init(canvas: HTMLCanvasElement, width: number, height: number) {
    this.width = width;
    this.app = new Application();
    await this.app.init({
      canvas: canvas as unknown as import("pixi.js").ICanvas,
      width,
      height,
      backgroundAlpha: 0,
      antialias: false,
    });

    const [catFrames, foodTextures] = await Promise.all([loadCatSprites(), loadFoodSprites()]);
    this.foodTextures = foodTextures;

    this.groundY = height - 40;

    this.app.stage.addChild(this.gameContainer);

    const catCount = width < 640 ? 2 : 3;
    const padding = 80;
    const availableWidth = width - padding * 2;
    const spacing = availableWidth / (catCount - 1 || 1);

    for (let i = 0; i < catCount; i++) {
      const x = catCount <= 1 ? width / 2 : padding + i * spacing;
      const cat = new CatEntity(catFrames, x, this.groundY, width);
      this.cats.push(cat);
      this.gameContainer.addChild(cat.container);
    }

    this.input.attach(canvas, (x: number) => this._dropFood(x));

    // Initialize demo cycle timers (staggered)
    this.permissionTimer = 0;
    this.permissionInterval = 8000 + Math.random() * 4000; // 8-12s
    this.taskCompleteTimer = 4000; // start 4s in so they don't both fire at once
    this.taskCompleteInterval = 15000 + Math.random() * 5000; // 15-20s

    this.app.ticker.add((ticker) => {
      const dt = ticker.deltaTime / 60;
      this._update(dt);
    });
  }

  private _update(dt: number) {
    // 1. Update foods
    const livingFoods: FoodEntity[] = [];
    for (const food of this.foods) {
      const alive = food.update(dt, this.groundY);
      if (alive) {
        livingFoods.push(food);
      } else {
        this.gameContainer.removeChild(food.sprite);
        food.destroy();
      }
    }
    this.foods = livingFoods;

    // 2. Update cats
    const mousePos = this.input.mousePos;
    for (const cat of this.cats) {
      const otherCats = this.cats.filter((c) => c !== cat);
      cat.update(dt, this.foods, otherCats, mousePos);
    }

    // 3. Demo cycle — trigger permission and taskComplete on idle cats
    this._updateDemoCycle(dt);
  }

  private _updateDemoCycle(dt: number) {
    const dtMs = dt * 1000;

    // Permission request demo
    this.permissionTimer += dtMs;
    if (this.permissionTimer >= this.permissionInterval) {
      this.permissionTimer = 0;
      this.permissionInterval = 8000 + Math.random() * 4000;

      const idleCat = this._randomIdleCat();
      if (idleCat) {
        idleCat.triggerPermissionRequest();
      }
    }

    // Task complete demo
    this.taskCompleteTimer += dtMs;
    if (this.taskCompleteTimer >= this.taskCompleteInterval) {
      this.taskCompleteTimer = 0;
      this.taskCompleteInterval = 15000 + Math.random() * 5000;

      const idleCat = this._randomIdleCat();
      if (idleCat) {
        idleCat.triggerTaskComplete();
      }
    }
  }

  private _randomIdleCat(): CatEntity | null {
    const idle = this.cats.filter((c) => c.state === "idle");
    if (idle.length === 0) return null;
    return idle[Math.floor(Math.random() * idle.length)];
  }

  private _dropFood(x: number) {
    if (this.foods.length >= PHYSICS.maxFoods) return;
    if (this.foodTextures.length === 0) return;

    const texture = this.foodTextures[Math.floor(Math.random() * this.foodTextures.length)];
    const food = new FoodEntity(texture, x, -20);
    this.foods.push(food);
    this.gameContainer.addChild(food.sprite);
  }

  resize(width: number, height: number) {
    if (!this.app) return;
    this.width = width;
    this.app.renderer.resize(width, height);
    this.groundY = height - 40;

    const catCount = this.cats.length;
    if (catCount === 0) return;

    const padding = 80;
    const availableWidth = width - padding * 2;
    const spacing = availableWidth / (catCount - 1 || 1);

    for (let i = 0; i < catCount; i++) {
      const x = catCount <= 1 ? width / 2 : padding + i * spacing;
      // Only reposition idle cats (don't interrupt animations)
      if (this.cats[i].state === "idle") {
        this.cats[i].x = x;
        this.cats[i].y = this.groundY;
      }
    }
  }

  destroy() {
    this.input.detach();
    if (this.app) {
      this.app.ticker.stop();
      for (const food of this.foods) {
        food.destroy();
      }
      this.foods = [];
      this.cats = [];
      this.app.destroy();
      this.app = null;
    }
  }
}
