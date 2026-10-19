/*
 * Copyright (C) 2017 The Android Open Source Project
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

package com.android.systemui.shared.recents;

import android.os.Bundle;
import android.view.KeyEvent;
import android.view.MotionEvent;

/**
 * The recents provider's calls into SystemUI (PowosRecentsService gets the binder in ILauncherProxy.onInitialize,
 * keyed by this descriptor): AOSP android16's ISystemUiProxy (frameworks/base packages/SystemUI/shared), only the calls
 * a gesture provider makes. The ids are the OnePlus Open's SystemUI's (its transaction codes minus one, read in its
 * decompiled ISystemUiProxy.Stub: startScreenPinning 2, onOverviewShown 7, onStatusBarTouchEvent 10, stopScreenPinning
 * 18, expandNotificationPanel 30, onBackEvent 45, toggleNotificationPanel 51, notifySwipeToRecentFinished 158), which
 * are AOSP's plus OnePlus's own at 151+; every one is one-way there. SystemUI checks the caller is the bound recents
 * provider's user (LauncherProxyService.verifyCaller).
 */
interface ISystemUiProxy {

    /** Pins task [taskId] to the screen (the switcher's "pin"). */
    oneway void startScreenPinning(int taskId) = 1;

    /** The switcher came up (from home, or over an app): SystemUI's nav bar and a11y follow it. */
    oneway void onOverviewShown(boolean fromHome) = 6;

    /** A touch on the status bar passed on to SystemUI (its own shade's pull, when PowOS doesn't take it). */
    oneway void onStatusBarTouchEvent(in MotionEvent event) = 9;

    /** Unpins the screen (gesture navigation's swipe up and hold while pinned). */
    oneway void stopScreenPinning() = 17;

    /** Opens SystemUI's notification panel. */
    oneway void expandNotificationPanel() = 29;

    /** A Back key event, as SystemUI's back button sends it (down, then up). */
    oneway void onBackEvent(in KeyEvent keyEvent) = 44;

    /** Opens or closes SystemUI's notification panel. */
    oneway void toggleNotificationPanel() = 50;

    /** OnePlus's: the swipe to recents is over (SystemUI notes it for its configuration changes). */
    oneway void notifySwipeToRecentFinished() = 157;
}
