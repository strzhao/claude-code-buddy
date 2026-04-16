import Foundation

// MARK: - DefaultSkinManifest

/// Static manifest for the built-in "Classic Cat" skin pack.
/// All values are precisely copied from the existing hardcoded sources:
/// - foodNames from FoodSprite.allFoodNames (102 items)
/// - animationNames from CatConstants
/// - bedNames, menuBar config from CatConstants / BuddyScene
enum DefaultSkinManifest {
    static let manifest = SkinPackManifest(
        id: "default",
        name: "Classic Cat",
        author: "Claude Code Buddy",
        version: "1.0.0",
        previewImage: nil,
        spritePrefix: "cat",
        animationNames: [
            "idle-a", "idle-b", "clean", "sleep", "scared",
            "paw", "walk-a", "walk-b", "jump"
        ],
        canvasSize: [48, 48],
        bedNames: ["bed-blue", "bed-gray", "bed-pink", "bed-green"],
        boundarySprite: "boundary-bush",
        foodNames: [
            "01_dish", "02_dish_2", "03_dish_pile", "04_bowl",
            "05_apple_pie", "06_apple_pie_dish", "07_bread", "08_bread_dish",
            "09_baguette", "10_baguette_dish", "11_bun", "12_bun_dish",
            "13_bacon", "14_bacon_dish", "15_burger", "16_burger_dish",
            "17_burger_napkin", "18_burrito", "19_burrito_dish",
            "20_bagel", "21_bagel_dish", "22_cheesecake", "23_cheesecake_dish",
            "24_cheesepuff", "25_cheesepuff_bowl", "26_chocolate", "27_chocolate_dish",
            "28_cookies", "29_cookies_dish", "30_chocolatecake", "31_chocolatecake_dish",
            "32_curry", "33_curry_dish", "34_donut", "35_donut_dish",
            "36_dumplings", "37_dumplings_dish", "38_friedegg", "39_friedegg_dish",
            "40_eggsalad", "41_eggsalad_bowl", "42_eggtart", "43_eggtart_dish",
            "44_frenchfries", "45_frenchfries_dish", "46_fruitcake", "47_fruitcake_dish",
            "48_garlicbread", "49_garlicbread_dish", "50_giantgummybear", "51_giantgummybear_dish",
            "52_gingerbreadman", "53_gingerbreadman_dish", "54_hotdog", "55_hotdog_sauce",
            "56_hotdog_dish", "57_icecream", "58_icecream_bowl",
            "59_jelly", "60_jelly_dish", "61_jam", "62_jam_dish",
            "63_lemonpie", "64_lemonpie_dish", "65_loafbread", "66_loafbread_dish",
            "67_macncheese", "68_macncheese_dish", "69_meatball", "70_meatball_dish",
            "71_nacho", "72_nacho_dish", "73_omlet", "74_omlet_dish",
            "75_pudding", "76_pudding_dish", "77_potatochips", "78_potatochips_bowl",
            "79_pancakes", "80_pancakes_dish", "81_pizza", "82_pizza_dish",
            "83_popcorn", "84_popcorn_bowl", "85_roastedchicken", "86_roastedchicken_dish",
            "87_ramen", "88_salmon", "89_salmon_dish",
            "90_strawberrycake", "91_strawberrycake_dish", "92_sandwich", "93_sandwich_dish",
            "94_spaghetti", "95_steak", "96_steak_dish",
            "97_sushi", "98_sushi_dish", "99_taco", "100_taco_dish",
            "101_waffle", "102_waffle_dish"
        ],
        foodDirectory: "Food",
        spriteDirectory: "Sprites",
        menuBar: MenuBarConfig(
            walkPrefix: "menubar-walk",
            walkFrameCount: 6,
            runPrefix: "menubar-run",
            runFrameCount: 5,
            idleFrame: "menubar-idle-1",
            directory: "Sprites/Menubar"
        )
    )
}
