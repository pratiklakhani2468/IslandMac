import SwiftUI

/// One displayed month, computed entirely with the system calendar (the user's locale, first
/// weekday and time zone). Pure date math, no Calendar-app access or events.
struct CalendarMonth: Equatable {
    let calendar: Calendar
    /// First instant of the displayed month.
    let start: Date

    init(containing date: Date, calendar: Calendar = .current) {
        self.calendar = calendar
        start = calendar.dateInterval(of: .month, for: date)!.start
    }

    func adding(months: Int) -> CalendarMonth {
        CalendarMonth(containing: calendar.date(byAdding: .month, value: months, to: start)!, calendar: calendar)
    }

    func contains(_ date: Date) -> Bool {
        calendar.isDate(date, equalTo: start, toGranularity: .month)
    }

    /// Localized month and year, e.g. "September 2026".
    var title: String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = calendar.locale ?? .current
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate("MMMMy")
        return formatter.string(from: start)
    }

    /// Very short weekday symbols, starting from the calendar's first weekday.
    var weekdaySymbols: [String] {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let first = calendar.firstWeekday - 1
        return Array(symbols[first...] + symbols[..<first])
    }

    /// Six full weeks of days, starting on the first weekday on or before the 1st, so every month
    /// is aligned to its weekdays and the grid never changes height.
    var days: [Date] {
        let leading = (calendar.component(.weekday, from: start) - calendar.firstWeekday + 7) % 7
        let gridStart = calendar.date(byAdding: .day, value: -leading, to: start)!
        return (0..<(CalendarLayout.weekRows * 7)).map { calendar.date(byAdding: .day, value: $0, to: gridStart)! }
    }
}

/// The Calendar page: a month grid for browsing dates. The displayed month is local to the page,
/// so it starts at the current month each time the page opens.
struct CalendarPageView: View {
    let onBack: () -> Void
    @State private var month: CalendarMonth
    /// +1 when moving forward in time, -1 backward: which way the grid slides.
    @State private var direction: CGFloat = 1

    init(showing date: Date = Date(), onBack: @escaping () -> Void) {
        self.onBack = onBack
        _month = State(initialValue: CalendarMonth(containing: date))
    }

    var body: some View {
        // Re-evaluated every minute so "today" stays correct across midnight while the page is open.
        TimelineView(.everyMinute) { context in
            let today = context.date
            VStack(spacing: 0) {
                header(today: today)
                weekdayRow
                ZStack {
                    grid(today: today)
                        .id(month.start)
                        // Sequenced like the island's handovers: the old month clears quickly, the new one
                        // slides in just after, so the two grids never interleave.
                        .transition(.asymmetric(
                            insertion: .offset(x: CalendarLayout.monthSlide * direction).combined(with: .opacity)
                                .animation(CalendarLayout.monthAnimation.delay(0.06)),
                            removal: .offset(x: -CalendarLayout.monthSlide * direction / 2).combined(with: .opacity)
                                .animation(.easeOut(duration: 0.09))))
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, CalendarLayout.horizontalPadding)
            .padding(.bottom, CalendarLayout.bottomPadding)
        }
    }

    private func header(today: Date) -> some View {
        HStack(spacing: 4) {
            PageBackButton(title: month.title, action: onBack)
            Spacer(minLength: 8)
            if !month.contains(today) {
                // Away from the current month: a way back, which also says "today is elsewhere".
                Button { go(to: CalendarMonth(containing: today)) } label: { CapsuleLabel(title: "Today") }
                    .buttonStyle(PressScaleStyle())
                    .help("Go to today")
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
            GlyphButton(symbol: "chevron.left", help: "Previous month") { go(to: month.adding(months: -1)) }
            GlyphButton(symbol: "chevron.right", help: "Next month") { go(to: month.adding(months: 1)) }
        }
        .animation(.easeOut(duration: 0.15), value: month.contains(today))
        .frame(height: CalendarLayout.headerHeight)
    }

    /// Direction is committed first, so the outgoing grid (which keeps the transition it was last
    /// drawn with) also leaves the right way; then the month changes with the page's spring.
    private func go(to target: CalendarMonth) {
        direction = target.start < month.start ? -1 : 1
        DispatchQueue.main.async {
            withAnimation(CalendarLayout.monthAnimation) { month = target }
        }
    }

    private var weekdayRow: some View {
        HStack(spacing: 0) {
            ForEach(Array(month.weekdaySymbols.enumerated()), id: \.offset) { _, symbol in
                Text(symbol)
                    .font(.system(size: 9.5, weight: .semibold))
                    .tracking(0.3)
                    .foregroundStyle(Ink.tertiary)
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(height: CalendarLayout.weekdayRowHeight)
    }

    private func grid(today: Date) -> some View {
        let days = month.days
        return VStack(spacing: 0) {
            ForEach(0..<CalendarLayout.weekRows, id: \.self) { week in
                HStack(spacing: 0) {
                    ForEach(days[(week * 7)..<(week * 7 + 7)], id: \.self) { day in
                        DayCell(number: month.calendar.component(.day, from: day),
                                inMonth: month.contains(day),
                                isToday: month.calendar.isDate(day, inSameDayAs: today))
                    }
                }
                .frame(height: CalendarLayout.rowHeight)
            }
        }
    }
}

private struct DayCell: View {
    let number: Int
    let inMonth: Bool
    let isToday: Bool

    var body: some View {
        Text("\(number)")
            .font(.system(size: 11.5, weight: isToday && inMonth ? .semibold : .medium).monospacedDigit())
            .foregroundStyle(isToday && inMonth ? Color.black : inMonth ? Ink.primary : Ink.quaternary)
            .frame(width: CalendarLayout.dayMarkSize, height: CalendarLayout.dayMarkSize)
            .background {
                if isToday && inMonth {
                    Circle().fill(.white)            // today, in the displayed month
                } else if isToday {
                    Circle().stroke(Ink.tertiary, lineWidth: 1) // today, spilling in from the next/previous month
                }
            }
            .frame(maxWidth: .infinity)
    }
}
