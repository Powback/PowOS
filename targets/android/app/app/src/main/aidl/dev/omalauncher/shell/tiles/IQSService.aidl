/*
 * Copyright 2015, The Android Open Source Project
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

package dev.omalauncher.shell.tiles;

import android.app.PendingIntent;
import android.content.ComponentName;
import android.graphics.drawable.Icon;
import android.service.quicksettings.Tile;

/**
 * A tile host's side, as a third-party TileService calls it (TileService.EXTRA_SERVICE): AOSP android16's
 * android.service.quicksettings.IQSService (frameworks/base core/java/android/service/quicksettings/IQSService.aidl,
 * android16-release, the same on main), every method in its order - the transaction codes are the order - and the
 * framework's descriptor, so the TileService's own IQSService.Stub.Proxy speaks to TileHost (shell/TileHost.kt).
 *
 * HACK: a copy of a hidden framework interface (@hide, not in the SDK), under its own name: the framework's class
 * of the same name would shadow an app's (the boot class path loads first). Real fix: none for an app - only SystemUI
 * hosts tiles in AOSP; a public tile-host API would be one.
 */
@Descriptor(value="android.service.quicksettings.IQSService")
interface IQSService {
    Tile getTile(in IBinder tile);
    void updateQsTile(in Tile tile, in IBinder service);
    void updateStatusIcon(in IBinder tile, in Icon icon,
            String contentDescription);
    void onShowDialog(in IBinder tile);
    void onStartActivity(in IBinder tile);
    void startActivity(in IBinder tile, in PendingIntent pendingIntent);
    boolean isLocked();
    boolean isSecure();
    void startUnlockAndRun(in IBinder tile);
    void onDialogHidden(in IBinder tile);
    void onStartSuccessful(in IBinder tile);
}
