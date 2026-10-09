# Process Elimination

A macOS 15 MenuBar applet for automatically quitting selected applications after their last window is closed and automatically force-quitting selected processes on a timer.

- Enter the name of processes you want automatically terminated on the configurable timer.
- Select applications you wish to be quit automatically when their last window is closed, after a configurable delay of 1–60 seconds (requires "Accessibility" permission to observe window existence).

This was actually born out of loathing for a bug in macOS 14's stupid video screensaver/wallpaper feature that caused the "WallpaperVideoExtension" process to regularly run up out-of-control CPU usage despite my not even using the feature. I never found a way to unload or disable the loading of that process, so good idea or not, I took to killing it in a loop, which did prevent that issue from reappearing.

While both the process force-quitting and application auto-quitting features are off by default, both do include a built-in default selection of entries which you will likely want to clear or customize before using.

## Installation and Usage

Process Elimination is not signed with an Apple Developer ID and is not notarized. To launch it, you can either disable Gatekeeper, remove the quarantine flag manually with the command below (using the appropriate path for your installation, of course), navigate to System Settings > Privacy & Security and click "Open Anyway" after first attempting a launch, or build it yourself with Xcode (open `Process Elimination.xcodeproj` in Xcode and choose Product > Build).

```sh
xattr -dr com.apple.quarantine "/Applications/Process Elimination.app"
```

In order to use the automatic application quitting functionality, you must grant Process Elimination "Accessibility" permission using the switch in System Settings > Privacy & Security > Accessibility. This will require authentication with an administrator account, but that authentication pertains to Apple's System Settings, not Process Elimination. macOS should prompt you about this on the first launch, but it might not. The process force-quitting functionality does not require this permission to work.

## System Requirements and Security

- macOS 15.6.0 or later, Apple Silicon only.
- Uses Apple's Hardened Runtime and is compliant with Swift 6 (Strict Concurrency and Strict Memory Safety); built against Xcode 26.3.
- A crude whitelist for the most critical system processes exists, but still, use good judgment in configuring the process force-quitting functionality since it does run on a timer.

## Support

If you find a bug, please report it here on GitHub and I will try to fix it. If it affects macOS 15, I will try harder. Please be as thorough in your reporting as you can.

You're welcome to request features or changes if you're so-inclined, and I will give such requests due consideration, but just know that this application was built first and foremost for an audience of one and I consider it largely feature-complete at this time.

Process Elimination is available in English only, by design.

## Note

I am not a software engineer; all of the code for this project was written by Anthropic's Claude models. That said, I use all of the applications under this account regularly in my daily life, so while they're not perfect, I'm confident in their efficacy and general reliability.

## License

Process Elimination is free software, licensed under the GNU General Public License, version 3 only (GPL-3.0-only). Copyright © 2025 avenged110. The full license text is in `COPYING`.

## Acknowledgments

Process Elimination includes a minimal, heavily feature-stripped reimplementation of portions of the Swindler library (https://github.com/tmandry/Swindler, Copyright © 2017 Tyler Mandry, MIT License), used as the basis for its "Accessibility"-based window observation. Process Elimination is not affiliated with, endorsed by, or supported by this author. The MIT notice is reproduced in the `NOTICES` folder and in the application's Credits.
