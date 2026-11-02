# Recipe to Grocery List

## App Store submission

App Store Connect requires a **13-inch iPad screenshot** and will not start review without it. Saying the app is iPhone-only does not remove the requirement. Every app in this family has had to ship an iPad version.

- `TARGETED_DEVICE_FAMILY` is `1,2` (iPhone and iPad). Do not set it back to `1`.
- Capture with `bash scripts/capture_app_store_screenshots.sh`.
- iPhone slot “iPhone with Dynamic Island (medium display)” accepts **1206×2622** only. 1320×2868 (6.9") is rejected there. Files: `build/app-store-screenshots/iphone-6.3/`.
- iPad slot “13-inch” accepts **2064×2752**. Files: `build/app-store-screenshots/ipad/`.
- After changing the device family, archive again and upload a new build. The build number has to be higher than the one already uploaded.

Do not put “free” or any price in the name, subtitle, promotional text, keywords, or screenshots (Guideline 2.3.7). The description may say the app is free.
