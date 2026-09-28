# Third-party notices

Status as of 2026-09-28: Mapper contains no third-party source files, no third-party binaries or frameworks, no Swift packages and no third-party assets (models, images, fonts or sounds). Everything in `ios/` is written for this project and uses only Apple system frameworks (ARKit, RoomPlan, RealityKit, SwiftUI, UIKit, ModelIO, Metal and Foundation), which ship with iOS and are not redistributed.

Anyone who adds third-party material must record it here in the same commit (see "How to add an entry").

## Apple documentation used as reference (no code copied)

The room, object and mesh capture flows are reimplemented from Apple's public documentation and WWDC session pages. No file from an Apple sample code project is included in this repository. The sample downloads could not be fetched from the build environment, so no sample source was read. Short usage patterns shown in Apple's documentation are rewritten in Mapper's own code. The details are in `docs/REUSE.md`.

RoomPlan:
- Create a 3D model of an interior room by guiding the user through an AR experience (sample page): https://developer.apple.com/documentation/roomplan/create-a-3d-model-of-an-interior-room-by-guiding-the-user-through-an-ar-experience
- Scanning the rooms of a single structure (article): https://developer.apple.com/documentation/roomplan/scanning-the-rooms-of-a-single-structure
- Merging multiple scans into a single structure (sample page): https://developer.apple.com/documentation/roomplan/merging-multiple-scans-into-a-single-structure
- RoomPlan reference pages for RoomCaptureView, RoomCaptureViewDelegate, RoomCaptureSession, RoomCaptureSessionDelegate, RoomBuilder, StructureBuilder, CapturedRoom, CapturedRoomData and CapturedStructure: https://developer.apple.com/documentation/roomplan
- WWDC22 session 10127, Create parametric 3D room scans with RoomPlan: https://developer.apple.com/videos/play/wwdc2022/10127/
- WWDC23 session 10192, Explore enhancements to RoomPlan: https://developer.apple.com/videos/play/wwdc2023/10192/

Object Capture:
- Scanning objects using Object Capture (sample page): https://developer.apple.com/documentation/realitykit/scanning-objects-using-object-capture
- RealityKit reference pages for ObjectCaptureSession, ObjectCaptureView, ObjectCapturePointCloudView and PhotogrammetrySession: https://developer.apple.com/documentation/realitykit
- WWDC23 session 10191, Meet Object Capture for iOS: https://developer.apple.com/videos/play/wwdc2023/10191/
- WWDC24 session 10107, Discover area mode for Object Capture: https://developer.apple.com/videos/play/wwdc2024/10107/

ARKit:
- Visualizing and interacting with a reconstructed scene (sample page): https://developer.apple.com/documentation/arkit/visualizing-and-interacting-with-a-reconstructed-scene
- ARKit reference pages for ARMeshAnchor, ARMeshGeometry, ARMeshClassification, ARSession, ARSessionDelegate and ARWorldTrackingConfiguration: https://developer.apple.com/documentation/arkit
- RealityKit ARView reference pages: https://developer.apple.com/documentation/realitykit/arview
- WWDC20 session 10611, Explore ARKit 4: https://developer.apple.com/videos/play/wwdc2020/10611/

## Open-source code

None yet.

Policy (from `docs/tasks/lead.md`): only MIT, BSD, Apache-2.0 or zlib licensed code, verified by reading the actual LICENSE file in the source repository. Never GPL, LGPL, AGPL, code with no license, or code with an unclear license. Prefer copying small, self-contained files over adding dependencies. No Swift packages.

## Apple Sample Code License

No Apple sample code is included today, so no Apple license text currently applies to this repository.

If a file from an Apple sample code project is ever copied into Mapper:
1. Download the sample zip and open its `LICENSE.txt` (Apple's samples ship their license in the zip, in the `LICENSE` folder or at the top level).
2. Paste the full text of that `LICENSE.txt` into this section, under a heading naming the sample, replacing the reference copy below. Different samples and years use different license texts; the text from the actual sample governs.
3. Keep Apple's copyright and license header at the top of every copied file, and add a line saying what Mapper changed.
4. Add an entry under "Entries" below (sample name and URL, files copied, what was changed).
5. Do not use Apple's name, logos or trademarks to promote Mapper; the license forbids it.

### Reference copy of the Apple sample code license

The text below could be fetched from an Apple page in the build environment; the current sample zips could not. It is the license Apple published for its archived Reachability sample (version 5.0, copyright 2016 Apple Inc.), at https://developer.apple.com/library/archive/samplecode/Reachability/Listings/LICENSE_txt.html. It is reproduced for reference only. Newer samples, including the three RoomPlan, Object Capture and ARKit samples above, may carry a different license text, which must replace this copy before any of their files is committed.

```
IMPORTANT:  This Apple software is supplied to you by Apple
Inc. ("Apple") in consideration of your agreement to the following
terms, and your use, installation, modification or redistribution of
this Apple software constitutes acceptance of these terms.  If you do
not agree with these terms, please do not use, install, modify or
redistribute this Apple software.

In consideration of your agreement to abide by the following terms, and
subject to these terms, Apple grants you a personal, non-exclusive
license, under Apple's copyrights in this original Apple software (the
"Apple Software"), to use, reproduce, modify and redistribute the Apple
Software, with or without modifications, in source and/or binary forms;
provided that if you redistribute the Apple Software in its entirety and
without modifications, you must retain this notice and the following
text and disclaimers in all such redistributions of the Apple Software.
Neither the name, trademarks, service marks or logos of Apple Inc. may
be used to endorse or promote products derived from the Apple Software
without specific prior written permission from Apple.  Except as
expressly stated in this notice, no other rights or licenses, express or
implied, are granted by Apple herein, including but not limited to any
patent rights that may be infringed by your derivative works or by other
works in which the Apple Software may be incorporated.

The Apple Software is provided by Apple on an "AS IS" basis.  APPLE
MAKES NO WARRANTIES, EXPRESS OR IMPLIED, INCLUDING WITHOUT LIMITATION
THE IMPLIED WARRANTIES OF NON-INFRINGEMENT, MERCHANTABILITY AND FITNESS
FOR A PARTICULAR PURPOSE, REGARDING THE APPLE SOFTWARE OR ITS USE AND
OPERATION ALONE OR IN COMBINATION WITH YOUR PRODUCTS.

IN NO EVENT SHALL APPLE BE LIABLE FOR ANY SPECIAL, INDIRECT, INCIDENTAL
OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
INTERRUPTION) ARISING IN ANY WAY OUT OF THE USE, REPRODUCTION,
MODIFICATION AND/OR DISTRIBUTION OF THE APPLE SOFTWARE, HOWEVER CAUSED
AND WHETHER UNDER THEORY OF CONTRACT, TORT (INCLUDING NEGLIGENCE),
STRICT LIABILITY OR OTHERWISE, EVEN IF APPLE HAS BEEN ADVISED OF THE
POSSIBILITY OF SUCH DAMAGE.

Copyright (C) 2016 Apple Inc. All Rights Reserved.
```

## How to add an entry

Add one block per reused source under "Entries":

```
### <name of the source>
- Source: <URL of the repository or sample page>
- License: <license name>, verified from <URL of the LICENSE file> on <date>
- Files: <paths in this repository>
- Changes: <what Mapper changed>
- License text: <the full license text or notice the license requires, pasted below>
```

## Entries

None.
