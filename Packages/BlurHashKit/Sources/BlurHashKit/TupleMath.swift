//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Foundation

@inlinable
func + (lhs: (Float, Float, Float), rhs: (Float, Float, Float)) -> (Float, Float, Float) {
    (lhs.0 + rhs.0, lhs.1 + rhs.1, lhs.2 + rhs.2)
}

@inlinable
func * (lhs: Float, rhs: (Float, Float, Float)) -> (Float, Float, Float) {
    (lhs * rhs.0, lhs * rhs.1, lhs * rhs.2)
}

@inlinable
func / (lhs: (Float, Float, Float), rhs: Float) -> (Float, Float, Float) {
    (lhs.0 / rhs, lhs.1 / rhs, lhs.2 / rhs)
}

func += (lhs: inout (Float, Float, Float), rhs: (Float, Float, Float)) {
    lhs = lhs + rhs
}
