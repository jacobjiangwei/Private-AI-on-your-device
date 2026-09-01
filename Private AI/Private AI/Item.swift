//
//  Item.swift
//  Private AI
//
//  Created by jacob on 2026/8/29.
//

import Foundation
import SwiftData

@Model
final class Item {
    var timestamp: Date
    
    init(timestamp: Date) {
        self.timestamp = timestamp
    }
}
