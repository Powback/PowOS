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

import android.graphics.Region;
import android.os.Bundle;

/**
 * SystemUI's calls to the recents provider (PowosRecentsService): AOSP android16's ILauncherProxy (the former
 * IOverviewProxy, frameworks/base packages/SystemUI/shared), only the calls PowOS takes. The ids are AOSP's, and the
 * OnePlus Open's SystemUI uses the same (its transaction codes, id + 1, checked in its decompiled ILauncherProxy:
 * onOverviewToggle 7, onInitialize 13, onUnbind 36); calls left out here (the nav bar's, OnePlus's own at 151+) reach
 * no method and are dropped, as every call here is one-way.
 *
 * onUnbind's IRemoteCallback is taken as its binder: the interface is hidden, PowosRecentsService answers it itself.
 */
oneway interface ILauncherProxy {

    /** The overview (recents) button: the switcher, or out of it. */
    void onOverviewToggle() = 6;

    /** The switcher asked for by the system (Alt-Tab, showRecentApps). */
    void onOverviewShown(boolean triggeredFromAltTab) = 7;

    /** The switcher to go away (Alt-Tab let go, hideRecentApps). */
    void onOverviewHidden(boolean triggeredFromAltTab, boolean triggeredFromHomeKey) = 8;

    /** Where the navigation bar takes gestures (gesture navigation's input monitor region). */
    void onActiveNavBarRegionChanges(in Region activeRegion) = 11;

    /** SystemUI connected: its ISystemUiProxy and the WM Shell interfaces, each keyed by its descriptor. */
    void onInitialize(in Bundle params) = 12;

    /** SystemUI's state flags (QuickStepContract.SYSUI_STATE_*): shade open, keyguard showing, nav mode, ... */
    void onSystemUiStateChanged(long stateFlags) = 16;

    /** SystemUI is unbinding: [reply] (an IRemoteCallback) is told once this side let go. */
    void onUnbind(IBinder reply) = 35;
}
