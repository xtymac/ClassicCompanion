# Classic Companion Beta

Version {{VERSION}}, build {{BUILD}}.

**This is a beta, not a stable release. Some acceptance checks are still open.**

Classic Companion opens the official ChatGPT website in a native macOS window. Press `⌥Space` to bring it up. The Quick window and the Full window show the same official page at different sizes; switch between them with `⌃⌘F`. Both shortcuts can be changed in Settings → Shortcuts.

Not an official OpenAI app and not affiliated with OpenAI.

## Requirements and testing

- Minimum requirements: macOS 15.0 or later, Apple silicon (arm64) only. Intel-based Macs aren’t supported.
- Verified on: one MacBook Pro with Apple M4 Max running macOS 27.2 (installing from the DMG, first launch, all four app languages and the main features).
- Not yet verified: macOS 15 and macOS 26; other Macs and fresh user accounts; installing from the ZIP; some physical-key and input-method actions, which have been tested only with tool-driven input; receiving an in-app update from the real update address; for Window Mode When Shown, VoiceOver speech and waking on a smaller screen where the window has to shrink.

## Install

From the DMG:
1. Double-click the downloaded DMG to open it.
2. In the window that opens, drag `Classic Companion` to the Applications folder.
3. Double-click it in Applications, then sign in to your ChatGPT account. You can eject the DMG afterwards.

From the ZIP:
1. Download the ZIP. Your browser may unzip it for you; if not, double-click the ZIP in Finder to get `Classic Companion`.
2. Drag it to the Applications folder before opening it.
3. Double-click it in Applications, then sign in to your ChatGPT account.

You don’t need Terminal for either.

This build is signed with Developer ID and notarized by Apple. The first time you open it, macOS may ask you to confirm; check that it’s Classic Companion and choose to open it. If macOS says the app can’t be opened, don’t change your Mac’s security settings; please report it on Issues instead.

## Updates

- Since 0.1.0-beta.2, Classic Companion can update itself: choose Check for Updates… in the Classic Companion menu, or turn on “Check for updates automatically” under Settings → General → Updates (the app also asks once, the second time you open it). When you choose to install an update, the app first asks you to confirm Download and Install. Nothing is downloaded or installed before you confirm, and nothing is installed when you quit. Once you confirm, Classic Companion quits, installs the update and reopens on its own as soon as the download is verified, without asking again.
- **0.1.0-beta.1 (build 20261110.0137) can’t update itself and won’t tell you about new versions.** If you’re using it, install this version once by hand using the steps above, replacing the old app in Applications; your sign-in and settings are kept. Later versions can then be installed from within the app.
- The update windows for checking, downloading and errors use your macOS language, not the language chosen in the app; the Download and Install confirmation follows the app’s language.

## Using it

- App language: the app’s interface is available in Simplified Chinese, Traditional Chinese, English and Japanese. By default it follows your macOS preferred languages (English if none of them match); you can change it under Settings → General → App Language, and the change takes effect immediately. It only affects this app’s own interface and doesn’t change the language of the ChatGPT web page, which you set in ChatGPT’s own settings. Menu items and dialogs supplied by macOS follow the macOS language.
- Settings has three panes: General (app language, page zoom, the window mode when shown, reopening the last chat, putting the cursor in the input box, Esc to hide, checking for updates automatically), Shortcuts, and Advanced (web enhancements, letting other apps read the web page, diagnostics).
- The app appears in the Dock and in `⌘Tab`, and has a menu bar icon. Clicking the Dock icon, switching to it with `⌘Tab` or opening the app again brings back the existing window without reloading the page.
- The close button and `⌘W` only hide the window; the app keeps running. `⌘Q` quits.
- Choose which window the show/hide shortcut (`⌥Space` by default) brings back under Settings → General → Window Mode When Shown. With Keep Last Mode, the default, the window comes back in the mode it was hidden in, so a Full window comes back as a Full window. With Always Quick Window it always appears as the Quick window, as in 0.1.0-beta.2 and earlier. Clicking the Dock icon, `⌘Tab` or opening the app again keeps the current mode whatever this setting is, and the app still starts in the Quick window.
- The wake shortcut is `⌥Space` by default. Open Settings with `⌘,` or from the menu bar icon, go to Shortcuts, click the box, then press the combination you want. You can record a combination that another app also uses, but pressing it later may trigger that app or stop the shortcut from working here. If another app opens a window while you record, Settings shows its name in orange; it’s best to choose a different combination or change the shortcut in that app. The Quick/Full window shortcut is `⌃⌘F` by default, can also be changed under Shortcuts, and works only while this app’s window is in front.
- At the top of the window, ✕ on the left hides the window, and the two buttons on the right start a new chat and switch between the Quick and Full window. Drag the empty area at the top to move the window, and double-click it to switch between the Quick and Full window (if System Settings is set to minimize when you double-click a title bar, the window minimizes instead). Light and dark appearance follow ChatGPT’s own theme setting.
- While web enhancements are on (the default, in Settings → Advanced), the Quick window hides ChatGPT’s own “Open sidebar” and “New chat” buttons in the page header; the new chat button at the top right and `⌘N` still work. This relies on the official page’s structure: after the page changes, or when the page switches to its wide layout because you widen the Quick window or zoom the page out, these buttons may appear. Everything else is the same as the website, and the sidebar, history and recent chats in search may still appear in the Quick window (for example when you open the sidebar with ChatGPT’s own shortcut or search with `⌘K`). Keep this in mind when sharing your screen.
- `⌘+`, `⌘-` and `⌘0` change the page size; text and page scale together. You can also choose it under Settings → General → Page Zoom. The Full window remembers the size you set.
- Read Aloud: use ChatGPT’s own Read Aloud button below each answer. Only start and stop are supported; pause, resume and speed aren’t, and starting again after stopping may not continue where it left off.

## Known issues

1. After you close an image preview, the thumbnail may be blank. A fix hasn’t been confirmed yet.
2. Interactive components haven’t been verified and may not display or work correctly in a chat.
3. If you regenerate an answer during Read Aloud, the old reading may keep playing; click ChatGPT’s stop button or quit the app. What happens when you switch chats, switch branches or hide the window with `⌥Space` during Read Aloud hasn’t been verified.
4. Scrolling quickly upward in a long chat occasionally bounces back. Safari behaves similarly; not fixed in this build.
5. Bringing up the window over another app’s full-screen space has been tested only with two displays, not with one.
6. When you edit a sent message in the Quick window, the edit box may end up above the visible area; scroll up a little to see it. Safari does the same in a narrow window but not in a wide one, so this is how the official page behaves; not fixed in this build.
7. After `⌘M`, opening the app again (other than by clicking the Dock) occasionally leaves the window at the Dock icon without expanding. Quitting and reopening the app restores it. The cause hasn’t been found yet.
8. On the test Mac, whose system language is English, the Edit menu shows Undo / Redo in English whatever the app language, and with the app in Chinese or Japanese the View menu has no Enter Full Screen and similar items. This was observed on the test Mac; the cause hasn’t been confirmed.
9. On the test Mac, whose preferred languages are English, Japanese and Simplified Chinese, choosing Traditional Chinese by hand shows punctuation in the app’s native windows in its Simplified Chinese or Japanese form (for example, “，” and “。” sit at the lower left instead of the center). This was observed on the test Mac; the cause hasn’t been confirmed.

## Feedback

Please report issues on GitHub Issues: https://github.com/xtymac/ClassicCompanion/issues

In About Classic Companion you can copy the version info, and the Diagnostics window (Settings → Advanced → Open Diagnostics) can copy a redacted report. Include them with a description of the problem. Issues are public, so don’t paste chat content, account details or private content from screenshots.

## Going back to an earlier version

Before going back, read the beta notes that came with the version you want and follow them; interface languages, icons and menus can differ between versions.

1. Press `⌘Q` to quit the app.
2. Delete the current `Classic Companion` from Applications.
3. Using that version’s DMG or ZIP, put the app into Applications as its notes describe, then open it.

Your sign-in is stored outside the app and isn’t deleted when you replace the app. Switching back and forth between any two versions isn’t guaranteed to work: an earlier version may not recognize, or may show differently, settings that a later version changed. If something goes wrong after going back, please report it on Issues.

## Uninstall

Quit the app, delete it, and delete the locations below. After deleting items 1 and 2 you’ll need to sign in again.

1. `~/Library/WebKit/local.classiccompanion.ClassicCompanion`
2. `~/Library/HTTPStorages/local.classiccompanion.ClassicCompanion.binarycookies`
3. `~/Library/Application Support/ClassicCompanion` (local diagnostics records)
4. `~/Library/Caches/local.classiccompanion.ClassicCompanion`
5. `~/Library/Preferences/local.classiccompanion.ClassicCompanion.plist`
