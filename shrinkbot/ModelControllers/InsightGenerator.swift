//
//  InsightGenerator.swift
//  shrinkbot
//
//  Created by Ethan John on 4/4/19.
//  Copyright © 2019 ya boy E. All rights reserved.
//

import Foundation
import CoreData
import SwiftUI

protocol InsightSource {
    func generate(completion: (([Insight]) -> ())?)
}

class InsightGenerator: InsightSource {
    
    static let shared = InsightGenerator()
    var cardName = ""
    
    func generate(completion: (([Insight]) -> ())? = nil) {
        let mainEntries = CardController.shared.activeCardEntries
        cardName = CardController.shared.activeCard?.name ?? ""
        guard mainEntries.count > 10 else { completion?([]) ; return  }
        DispatchQueue.global().async {
            let tmpContext = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
            tmpContext.parent = CoreDataStack.context
            let tmpEntries = mainEntries.map{ tmpContext.object(with: $0.objectID) as! Entry }
            var insights = [Insight]()
            let overallAnalysis = self.generateOverallAnalysis(entries: tmpEntries)
            let averageFrequency = self.averageFactorFrequency(entries: tmpEntries)
            let mainProgress = self.getMainProgress(entries: tmpEntries)
            func firstTwo(_ insights: [Insight]) -> [Insight] {
                let shuffled = insights.shuffled()
                guard insights.count > 2 else { return shuffled }
                return shuffled.dropLast(insights.count - 2)
            }
            insights.append(contentsOf: firstTwo(overallAnalysis))
            insights.append(contentsOf: firstTwo(averageFrequency))
            insights.append(contentsOf: firstTwo(mainProgress))
            let filteredByScore = insights.filter{ $0.score > 20 }
            DispatchQueue.main.async {
                completion?(filteredByScore)
            }
        }
    }
    
    private func getMainProgress(entries: [Entry]) -> [Insight] {
        let week = CardController.shared.getRecentEntriesIn(entries: entries, interval: .week)
        let month = CardController.shared.getRecentEntriesIn(entries: entries, interval: .month)
        let weekRatings = week.map{ $0.rating }
        let monthRatings = month.map{ $0.rating }
        if weekRatings == monthRatings {
            return []
        }
        let percentDifference = percentChange(from: monthRatings.average, to: weekRatings.average)
        let rounded = ((percentDifference * 10).rounded()) / 10
        let monthAverage = monthRatings.average
        let weekAverage = weekRatings.average
        let difference = abs(weekAverage - monthAverage)
        var significant = false
        if difference > 1 {
            significant = true
        }
        var description = "This week \(cardName) is \(significant ? "significantly" : "a bit") \(rounded > 0 ? "better" : "worse") than this month's average"
        if abs(percentDifference) == 0 {
            description = "Looks like this week is about the same as the rest of the month for \(cardName)"
        }
        return [Insight(title: cardName, description: description, score: Double.random(in: 0...50))]
    }
    
    private func averageFactorFrequency(entries: [Entry]) -> [Insight] {
        var insights = [Insight]()
        let sorted = sortIntoGroupsByFactorType(entries: entries)
        for type in sorted.keys {
            guard let entriesWithType = sorted[type] else { continue }
            let groups = CardController.shared.getEntries(entries: entries, groupedBy: .day)
            let analyses = intervalAnalysesWith(groups: groups, type: type)
            var recordedPerInterval = [Int]()
            for analysis in analyses {
                recordedPerInterval.append(analysis.factorRecorded)
            }
            let sorted = entriesWithType.sorted { first, second -> Bool in
                first.date! < second.date!
            }.first?.date ?? Date()
            let dayCount = Calendar.current.dateComponents([.day], from: sorted, to: Date()).day ?? 0
            let zeroDays = (0..<dayCount).map { _ in 0 }
            let roundedRecorded = ((recordedPerInterval + zeroDays).average)
            let randomScore = Double.random(in: 0...80)
            if roundedRecorded < 1 {
                insights.append(Insight(title: "\(type.name ?? "Name") Frequency", description: "On average you record \(type.name ?? "Name") about once every \(String(format: "%.f", (1 / roundedRecorded))) days", score: randomScore))
            } else {
                insights.append(Insight(title: "\(type.name ?? "Name") Frequency", description: "On average you record \(type.name ?? "Name") \(String(format:"%.2f", roundedRecorded)) times every day", score: randomScore))
            }
        }
        return insights
    }
    
    /// Analyze data by interval - If average interval between recorded factor is >= a week we will analyze by week. Weeks with factor included are compared to weeks with factor not included. Entries that have the factor recorded on them should not be used to analyze the data otherwise it may be skewed
    private func generateOverallAnalysis(entries: [Entry]) -> [Insight] {
        
        let allEntries = entries
        let entriesByFactorType = sortIntoGroupsByFactorType(entries: allEntries)
        var intervalAnalyses = [FactorType: [IntervalAnalysis]]()
        for type in entriesByFactorType.keys {
            guard let entries = entriesByFactorType[type] else { print("No entries sorted by this type") ; continue }
            let average = averageIntervalBetween(entries: entries)
            let interval = closestCalendarIntervalWith(input: average)
            guard let intervalSafe = interval else { continue }
            let grouped = CardController.shared.getEntries(entries: allEntries, groupedBy: intervalSafe)
            intervalAnalyses[type] = intervalAnalysesWith(groups: grouped, type: type)
        }
        var insights = [Insight]()
        for type in intervalAnalyses.keys {
            var withFactor = [Double]()
            var withoutFactor = [Double]()
            guard let analysisGroup = intervalAnalyses[type] else { continue }
            for analysis in analysisGroup {
                analysis.factorRecorded > 0 ? withFactor.append(analysis.avgRating) : withoutFactor.append(analysis.avgRating)
            }
            let withAverage = withFactor.average
            let withoutAverage = withoutFactor.average
            let difference = abs(withAverage - withoutAverage)
            let betterWith = withAverage > withoutAverage
            var significant = false
            if difference > 1 {
                significant = true
            }
            insights.append(Insight(title: "\(type.name ?? "Name") / \(cardName) Correlation", description: "\(cardName) is \(significant ? "a bit" : "significantly") \(betterWith ? "better" : "worse") with \(type.name ?? "Name")", score: analysisGroup.map{ $0.score }.reduce(0, +)))
        }
        return insights
    }
    
    private func sortIntoGroupsByFactorType(entries: [Entry]) -> [FactorType:[Entry]] {
        var entriesByFactorType = [FactorType : [Entry]]()
        for entry in entries {
            let marks = CardController.shared.getMarks(entry: entry)
            for mark in marks {
                guard let type = mark.type else { continue }
                if entriesByFactorType[type] == nil {
                    entriesByFactorType[type] = [entry]
                } else {
                    entriesByFactorType[type]?.append(entry)
                }
            }
        }
        return entriesByFactorType
    }
    
    private func averageIntervalBetween(entries: [Entry]) -> TimeInterval {
        var lastDate: Date?
        var intervals = [TimeInterval]()
        for entry in entries {
            guard let date = entry.date else { continue }
            if lastDate != nil {
                intervals.append(date.timeIntervalSince(lastDate!))
            }
            lastDate = date
        }
        return intervals.average
    }
    
    /// Will find the smallest calendar interval that can contain the interval that is passed into the function.
    private func closestCalendarIntervalWith(input: TimeInterval) -> EntryDateStyles? {
        var interval: EntryDateStyles?
        if input >= 0, input < day {
            interval = .day
        } else if input >= day, input < week {
            interval = .week
        } else if input >= week, input < month {
            interval = .month
        } else if input >= month, input < year {
            print("Entries are more than a month apart.")
        } else {
            print("Relevant entries are more than a year apart.")
        }
        return interval
    }
    
    private func percentChange(from initialValue: Double, to changedValue: Double) -> Double {
        let delta = changedValue - initialValue
        return (delta / initialValue) * 100
    }
    
    private func intervalAnalysesWith(groups: [[Entry]], type: FactorType) -> [IntervalAnalysis] {
        var intervalAnalyses = [IntervalAnalysis]()
        var reliability = Double()
        for group in groups {
            var ratings = [Double]()
            var factorRecorded = 0
            for entry in group {
                let marks = CardController.shared.getMarks(entry: entry)
                marks.forEach {
                    if $0.type == type {
                        factorRecorded += 1
                        reliability += 1
                    }
                }
                if marks.isEmpty {
                    ratings.append(entry.rating)
                }
            }
            let analysis = IntervalAnalysis(avgRating: ratings.average, forFactor: type, intervalEntries: group, factorRecorded: factorRecorded, reliability: reliability)
            intervalAnalyses.append(analysis)
        }
        return intervalAnalyses
    }
}

// MARK: - Other ideas for insights
// Time since last mark. Ex. It's been 18 days & 5 hours since you recorded (A)
// Progress. Ex. This week (Main) has improved by 20% / (Main) has gotten 8% worse. How to decide the interval to look at?
