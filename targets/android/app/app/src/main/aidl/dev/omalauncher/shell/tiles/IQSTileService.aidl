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

/**
 * A third-party tile's side, the binder its TileService returns from onBind: AOSP android16's
 * android.service.quicksettings.IQSTileService (frameworks/base core/java/android/service/quicksettings/
 * IQSTileService.aidl, android16-release, the same on main), every method in its order (the transaction codes) and
 * one-way, as there, under the framework's descriptor.
 *
 * HACK: a copy of a hidden framework interface, as IQSService.aidl says. Real fix: the same.
 */
@Descriptor(value="android.service.quicksettings.IQSTileService")
oneway interface IQSTileService {
    void onTileAdded();
    void onTileRemoved();
    void onStartListening();
    void onStopListening();
    void onClick(IBinder wtoken);
    void onUnlockComplete();
}
