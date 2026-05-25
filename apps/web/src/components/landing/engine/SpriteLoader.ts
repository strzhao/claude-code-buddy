// Loads all cat sprite textures from /sprites/cats/cat-{anim}-{frame}.png
// Loads food textures from /sprites/food/{name}.png
// Sets scaleMode = 'nearest' on all textures for pixel-perfect rendering
// Returns a map of AnimationName -> Texture[]

import type { Texture } from "pixi.js";
import { Assets } from "pixi.js";
import { FRAME_COUNTS, type AnimationName } from "./types";

export type SpriteFrameMap = Record<AnimationName, Texture[]>;

export async function loadCatSprites(): Promise<SpriteFrameMap> {
  const result = {} as SpriteFrameMap;

  const animations = Object.keys(FRAME_COUNTS) as AnimationName[];

  for (const anim of animations) {
    const count = FRAME_COUNTS[anim];
    const textures: Texture[] = [];

    for (let i = 1; i <= count; i++) {
      const url = `/sprites/cats/cat-${anim}-${i}.png`;
      const texture: Texture = await Assets.load(url);
      texture.source.scaleMode = "nearest";
      textures.push(texture);
    }

    result[anim] = textures;
  }

  return result;
}

const FOOD_NAMES = [
  "01_dish",
  "04_bowl",
  "07_bread",
  "15_burger",
  "22_cheesecake",
  "26_chocolate",
  "34_donut",
  "44_frenchfries",
  "57_icecream",
  "79_pancakes",
  "81_pizza",
  "87_ramen",
  "90_strawberrycake",
  "95_steak",
  "97_sushi",
];

export async function loadFoodSprites(): Promise<Texture[]> {
  const textures: Texture[] = [];

  for (const name of FOOD_NAMES) {
    const url = `/sprites/food/${name}.png`;
    const texture: Texture = await Assets.load(url);
    texture.source.scaleMode = "nearest";
    textures.push(texture);
  }

  return textures;
}
