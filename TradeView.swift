import SwiftUI
import Combine
// MARK: - Gold color
extension Color {
    static let gold = Color(red: 212/255, green: 175/255, blue: 55/255)
}

// Subtle pressed-state opacity style
struct PressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.6 : 1.0)
    }
}

// MARK: - TradeSide / OrderType
enum TradeSide: String, CaseIterable {
    case buy, sell
}

enum OrderType: String, CaseIterable {
    case market
    case limit
    case stopLimit = "stop-limit"
    case trailingStop = "trailing stop"
}

// ------------------------------------------------------------------------
// REMOVED local PaymentMethod struct from here to avoid conflict with
// PaymentMethodsView.swift
// ------------------------------------------------------------------------

// MARK: - TradeView
struct TradeView: View {
    @Namespace private var depthNamespace
    @State private var breathe = false
    
    // The symbol to trade (default "BTC")
    @State private var symbol: String
    
    // Whether to show a "Back" button
    private let showBackButton: Bool
    
    // Main ViewModels
    @StateObject private var vm: TradeViewModel
    @StateObject private var orderBookVM = OrderBookViewModel()
    @StateObject private var priceVM: PriceViewModel
    
    // UI states
    // Removed selectedChartType and chart toggle since TradingView is not used currently.
    @State private var selectedInterval: ChartInterval = .oneHour
    @State private var selectedSide: TradeSide = .buy
    @State private var orderType: OrderType = .market

    @State private var quantity: String = ""
    @State private var limitPrice: String = ""
    @State private var stopPrice: String = ""

    // Slider from 0..1 so user can pick a fraction of “balance”
    @State private var sliderValue: Double = 0.0

    // Coin picker
    @State private var isCoinPickerPresented = false
    @State private var isOrderBookModalPresented: Bool = false

    // Removed Payment Method selection since it's no longer needed.
    // @State private var selectedPaymentMethod: PaymentMethod = PaymentMethod(name: "Coinbase", details: "Coinbase Exchange")
    // @State private var isPaymentMethodPickerPresented = false

    @State private var showSlippageDialog: Bool = false
    @State private var slippageTolerance: Double = 0.5
    // Access horizontal size class for compact layout
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @Environment(\.presentationMode) var presentationMode
    @Environment(\.colorScheme) var colorScheme
    @State private var priceHighlight = false
    @State private var highlightedBids: Set<String> = []
    @State private var highlightedAsks: Set<String> = []
    @State private var previousBidMap: [String: String] = [:]
    @State private var previousAskMap: [String: String] = [:]
    @State private var hasLoadedOrderBook = false

    // MARK: - Keyboard Height State
    @State private var keyboardHeight: CGFloat = 0
    // Publisher for keyboard height
    private var keyboardPublisher: AnyPublisher<CGFloat, Never> {
        Publishers.Merge(
            NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)
                .compactMap { $0.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect }
                .map { $0.height },
            NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)
                .map { _ in CGFloat(0) }
        )
        .eraseToAnyPublisher()
    }

    // MARK: - Order Book Depth Bar Max Values
    private var maxBidValue: Double {
        let values = orderBookVM.bids.prefix(5).compactMap { entry -> Double? in
            guard let p = Double(entry.price), let q = Double(entry.qty) else { return nil }
            return p * q
        }
        return values.max() ?? 1
    }

    private var maxAskValue: Double {
        let values = orderBookVM.asks.prefix(5).compactMap { entry -> Double? in
            guard let p = Double(entry.price), let q = Double(entry.qty) else { return nil }
            return p * q
        }
        return values.max() ?? 1
    }

    // MARK: - Order Book Depth Calculations
    private func bidDepth(_ entry: OrderBookViewModel.OrderBookEntry) -> CGFloat {
        let value = (Double(entry.price).flatMap { p in Double(entry.qty).map { q in p * q } } ?? 0)
        return CGFloat(value / maxBidValue)
    }

    private func askDepth(_ entry: OrderBookViewModel.OrderBookEntry) -> CGFloat {
        let value = (Double(entry.price).flatMap { p in Double(entry.qty).map { q in p * q } } ?? 0)
        return CGFloat(value / maxAskValue)
    }

    // MARK: - Order Book Column Subviews
    private func bidsColumn(width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(orderBookVM.bids.prefix(10).enumerated()), id: \.element.price) { index, bid in
                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(
                            LinearGradient(
                                gradient: Gradient(colors: {
                                    let base = highlightedBids.contains(bid.price) ? 0.5 : 0.3
                                    let pulse = bidDepth(bid) < 0.2 ? (breathe ? 0.1 : 0) : 0
                                    return [
                                        Color.green.opacity(base + pulse),
                                        Color.green.opacity(0)
                                    ]
                                }()),
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: max(width * bidDepth(bid), 4), height: 20)
                        .cornerRadius(4)
                    HStack {
                        Text(formatPriceWithCommas(Double(bid.price) ?? 0))
                            .font(.caption2)
                            .foregroundColor(.white)
                        Spacer()
                        Text(bid.qty)
                            .font(.caption2)
                            .foregroundColor(.white)
                    }
                    .frame(width: width, height: 20)
                    .padding(.horizontal, 4)
                }
                .matchedGeometryEffect(id: bid.price, in: depthNamespace)
                .frame(width: width, height: 20)
                .clipped()
                .contentShape(Rectangle())
                .onTapGesture {
                    orderType = .limit
                    limitPrice = bid.price
                }
                .animation(
                    Animation.spring(response: 0.4, dampingFraction: 0.7)
                        .delay(Double(index) * 0.03),
                    value: orderBookVM.bids
                )
            }
        }
    }

    private func asksColumn(width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(orderBookVM.asks.prefix(10).enumerated()), id: \.element.price) { index, ask in
                ZStack(alignment: .trailing) {
                    Rectangle()
                        .fill(
                            LinearGradient(
                                gradient: Gradient(colors: {
                                    let base = highlightedAsks.contains(ask.price) ? 0.5 : 0.3
                                    let pulse = askDepth(ask) < 0.2 ? (breathe ? 0.1 : 0) : 0
                                    return [
                                        Color.red.opacity(base + pulse),
                                        Color.red.opacity(0)
                                    ]
                                }()),
                                startPoint: .trailing,
                                endPoint: .leading
                            )
                        )
                        .frame(width: max(width * askDepth(ask), 4), height: 20)
                        .cornerRadius(4)
                    HStack {
                        Text(formatPriceWithCommas(Double(ask.price) ?? 0))
                            .font(.caption2)
                            .foregroundColor(.white)
                        Spacer()
                        Text(ask.qty)
                            .font(.caption2)
                            .foregroundColor(.white)
                    }
                    .frame(width: width, height: 20)
                    .padding(.horizontal, 4)
                }
                .matchedGeometryEffect(id: ask.price, in: depthNamespace)
                .frame(width: width, height: 20)
                .clipped()
                .contentShape(Rectangle())
                .onTapGesture {
                    orderType = .limit
                    limitPrice = ask.price
                }
                .animation(
                    Animation.spring(response: 0.4, dampingFraction: 0.7)
                        .delay(Double(index) * 0.03),
                    value: orderBookVM.asks
                )
            }
        }
    }
    
    // MARK: - Init
    init(symbol: String = "BTC", showBackButton: Bool = false) {
        _symbol = State(initialValue: symbol.uppercased())
        self.showBackButton = showBackButton
        _priceVM = StateObject(wrappedValue: PriceViewModel(symbol: symbol.uppercased(), timeframe: .live))
        _vm = StateObject(wrappedValue: TradeViewModel(symbol: symbol.uppercased()))
    }
    

    @ViewBuilder
    private var tradeContent: some View {
        let isCompact = horizontalSizeClass == .compact
        GeometryReader { geometry in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    navBar

                    priceRow

                    chartSection
                        .id("\(symbol)-\(selectedInterval.rawValue)")
                        .zIndex(1)
                        .frame(height: 250)
                        .clipShape(RoundedRectangle(cornerRadius: 12))

                    intervalPicker
                        .zIndex(999)
                        .padding(.vertical, 2)

                    TradeFormView(
                        quantity: $quantity,
                        limitPrice: $limitPrice,
                        stopPrice: $stopPrice,
                        selectedSide: $selectedSide,
                        orderType: $orderType,
                        slippageTolerance: $slippageTolerance,
                        showSlippageDialog: $showSlippageDialog,
                        sliderValue: $sliderValue,
                        vm: vm,
                        priceVM: priceVM,
                        symbol: symbol,
                        horizontalSizeClass: horizontalSizeClass
                    )
                    .padding(.top, 8)

                    orderBookSection
                }
                .padding(.horizontal, isCompact ? 8 : 16)
                .frame(maxWidth: horizontalSizeClass == .regular ? 600 : .infinity)
                .frame(maxWidth: .infinity, alignment: .center)
                .frame(minHeight: geometry.size.height)
            }
            .padding(.bottom, keyboardHeight + geometry.safeAreaInsets.bottom + 16)
            .ignoresSafeArea(edges: .bottom)
        }
    }

    var body: some View {
        NavigationStack {
            tradeContent
        }
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .background(FuturisticBackground().ignoresSafeArea())
        .navigationBarBackButtonHidden(true)
        .onAppear {
            let coinID = symbol.uppercased() + "USDT"
            priceVM.startLiveUpdates(coinID: coinID)
            orderBookVM.startFetchingOrderBook(for: symbol)
            // start breathing effect
            withAnimation(Animation.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                breathe.toggle()
            }
        }
        .onChange(of: symbol) { newSymbol in
            hasLoadedOrderBook = false
            symbol = newSymbol
            vm.currentSymbol = newSymbol
            // Restart priceVM live updates for new symbol
            priceVM.stopPolling()
            let newCoinID = newSymbol.uppercased() + "USDT"
            priceVM.startLiveUpdates(coinID: newCoinID)
            // orderBookVM and vm updated, but priceVM symbol/polling now handled onAppear only
            orderBookVM.startFetchingOrderBook(for: newSymbol)
            vm.fetchBalance(for: newSymbol)
        }
        .onDisappear {
            priceVM.stopPolling()
            orderBookVM.stopFetching()
        }
        .onReceive(keyboardPublisher) { height in
            keyboardHeight = height
        }
        .sheet(isPresented: $isCoinPickerPresented) {
            EnhancedCoinPickerView(currentSymbol: $symbol) { newCoin in
                symbol = newCoin
                vm.currentSymbol = newCoin
                orderBookVM.startFetchingOrderBook(for: newCoin)
            }
        }
        .sheet(isPresented: $isOrderBookModalPresented) {
            // existing order book modal content
            VStack {
                HStack {
                    Text("Order Book")
                        .font(.title2)
                        .bold()
                        .foregroundColor(.white)
                    Spacer()
                    Button("Close") {
                        isOrderBookModalPresented = false
                    }
                    .foregroundColor(.yellow)
                }
                .padding()

                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            VStack(alignment: .leading) {
                                Text("Bids")
                                    .font(.headline)
                                    .foregroundColor(.green)
                                ForEach(orderBookVM.bids, id: \.price) { bid in
                                    Text("\(bid.price) | \(bid.qty)")
                                        .foregroundColor(.white)
                                        .font(.caption)
                                }
                            }
                            Spacer()
                            VStack(alignment: .leading) {
                                Text("Asks")
                                    .font(.headline)
                                    .foregroundColor(.red)
                                ForEach(orderBookVM.asks, id: \.price) { ask in
                                    Text("\(ask.price) | \(ask.qty)")
                                        .foregroundColor(.white)
                                        .font(.caption)
                                }
                            }
                        }
                    }
                    .padding()
                }
                .background(Color.black)
            }
            .background(Color.black.ignoresSafeArea())
        }
    }
    
    // MARK: - Nav Bar
private var navBar: some View {
    HStack(alignment: .center) {
        if showBackButton {
            Button {
                presentationMode.wrappedValue.dismiss()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                        .foregroundColor(.yellow)
                    Text("Back")
                        .foregroundColor(.yellow)
                }
            }
        }
        
        Spacer()
        
        HStack(spacing: 8) {
            CoinImageView(symbol: symbol, url: nil, size: 18)
            Text(symbol.uppercased())
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(.white)
            
            Button {
                isCoinPickerPresented = true
            } label: {
                Image(systemName: "chevron.down")
                    .foregroundColor(.white)
            }
        }
        
        Spacer()
    }
    .padding(.horizontal, horizontalSizeClass == .compact ? 8 : 16)
    .padding(.vertical, 2)
    .background(Color.black.opacity(0.2)) // subtle background for visual separation
}
    
    // MARK: - Price Row
    private var priceRow: some View {
        HStack(spacing: 6) {
            Text(formatPriceWithCommas(priceVM.price))
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundColor(.gold)
                .shadow(color: Color.black.opacity(0.8), radius: 1, x: 0, y: 1)
                .shadow(color: Color.gold.opacity(priceHighlight ? 0.4 : 0.2), radius: priceHighlight ? 4 : 2, x: 0, y: 0)
                .animation(.easeInOut(duration: 0.2), value: priceHighlight)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, horizontalSizeClass == .compact ? 8 : 16)
        .background(Color.white.opacity(0.05))
        .onChange(of: priceVM.price) { _ in
            withAnimation(.easeInOut(duration: 0.15)) {
                priceHighlight = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                withAnimation(.easeInOut(duration: 0.2)) {
                    priceHighlight = false
                }
            }
        }
    }
    
    // A comma-based price formatter
    private func formatPriceWithCommas(_ value: Double) -> String {
        guard value > 0 else { return "$0.00" }
        
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        
        if value < 1.0 {
            formatter.minimumFractionDigits = 2
            formatter.maximumFractionDigits = 8
        } else {
            formatter.minimumFractionDigits = 2
            formatter.maximumFractionDigits = 2
        }
        
        return "$" + (formatter.string(from: NSNumber(value: value)) ?? "0.00")
    }
    
    // MARK: - Chart
    @ViewBuilder
    private var chartSection: some View {
        CryptoChartView(symbol: symbol, interval: selectedInterval, height: 250)
    }
    
    // MARK: - Interval Picker
    private var intervalPicker: some View {
        ScrollViewReader { proxy in
            let isCompact = horizontalSizeClass == .compact
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: isCompact ? 4 : 8) {
                    ForEach(ChartInterval.allCases, id: \.self) { interval in
                        Button {
                            withAnimation(.easeInOut) {
                                selectedInterval = interval
                            }
                        } label: {
                            Text(interval.rawValue)
                                .font(.caption2)
                                .fontWeight(.semibold)
                                .padding(.vertical, 6)
                                .padding(.horizontal, 14)
                                .background(
                                    RoundedRectangle(cornerRadius: 12)
                                        .fill(
                                            selectedInterval == interval
                                            ? Color.yellow
                                            : Color.black.opacity(0.3)
                                        )
                                )
                                .foregroundColor(selectedInterval == interval ? .black : .white)
                        }
                        .id(interval)
                    }
                }
                .padding(.horizontal, isCompact ? 8 : 12)
            }
            .frame(height: isCompact ? 40 : 44)
            .onChange(of: selectedInterval) { newInterval in
                withAnimation(.easeInOut) {
                    proxy.scrollTo(newInterval, anchor: .center)
                }
            }
        }
    }
    
    // MARK: - Chart Type Toggle
    // REMOVED: Chart type toggle has been removed.
    

// MARK: – TradeFormView extracted to reduce compiler load
struct TradeFormView: View {
    @Binding var quantity: String
    @Binding var limitPrice: String
    @Binding var stopPrice: String
    @Binding var selectedSide: TradeSide
    @Binding var orderType: OrderType
    @Binding var slippageTolerance: Double
    @Binding var showSlippageDialog: Bool
    @Binding var sliderValue: Double

    @ObservedObject var vm: TradeViewModel
    @ObservedObject var priceVM: PriceViewModel
    let symbol: String
    let horizontalSizeClass: UserInterfaceSizeClass?

    private func formatPriceWithCommas(_ value: Double) -> String {
        guard value > 0 else { return "$0.00" }
        let f = NumberFormatter()
        f.numberStyle = .decimal
        if value < 1 { f.minimumFractionDigits = 2; f.maximumFractionDigits = 8 }
        else      { f.minimumFractionDigits = 2; f.maximumFractionDigits = 2 }
        return "$" + (f.string(from: NSNumber(value: value)) ?? "0.00")
    }

    // MARK: – Section Subviews to reduce body complexity
    private struct FeeCostSection: View {
        let fee: Double
        let totalCost: Double
        @Binding var selectedSide: TradeSide
        @Binding var slippageTolerance: Double
        @Binding var showSlippageDialog: Bool

        var body: some View {
            HStack(alignment: .top, spacing: 16) {
                // Estimated fee & Total cost
                VStack(spacing: 4) {
                    HStack {
                        Text("Estimated fee:")
                            .font(.caption)
                            .foregroundColor(.gray)
                        Spacer()
                        Text(formatPriceWithCommas(fee))
                            .font(.caption)
                            .foregroundColor(.gray)
                    }
                    HStack {
                        Text("Total cost:")
                            .font(.caption)
                            .foregroundColor(.white)
                        Spacer()
                        Text(formatPriceWithCommas(totalCost))
                            .font(.caption)
                            .foregroundColor(.white)
                    }
                }
                Spacer()
                // Buy/Sell Toggle
                HStack(spacing: 2) {
                    Button { selectedSide = .buy } label: {
                        Text("Buy")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(selectedSide == .buy ? .black : .white)
                            .padding(.vertical, 10)
                            .padding(.horizontal, 16)
                            .background(selectedSide == .buy ? Color.yellow : Color.white.opacity(0.15))
                            .cornerRadius(10)
                    }
                    Button { selectedSide = .sell } label: {
                        Text("Sell")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(.white)
                            .padding(.vertical, 10)
                            .padding(.horizontal, 16)
                            .background(selectedSide == .sell ? Color.red : Color.white.opacity(0.15))
                            .cornerRadius(10)
                    }
                }
            }
            .padding(.horizontal, 12)
            .confirmationDialog("Select Slippage", isPresented: $showSlippageDialog, titleVisibility: .visible) {
                ForEach([0.1, 0.5, 1.0, 2.0], id: \.self) { pct in
                    Button("\(Int(pct*100))%") { slippageTolerance = pct }
                }
            }
        }

        private func formatPriceWithCommas(_ value: Double) -> String {
            guard value > 0 else { return "$0.00" }
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            if value < 1.0 {
                formatter.minimumFractionDigits = 2
                formatter.maximumFractionDigits = 8
            } else {
                formatter.minimumFractionDigits = 2
                formatter.maximumFractionDigits = 2
            }
            return "$" + (formatter.string(from: NSNumber(value: value)) ?? "0.00")
        }
    }

    // MARK: – OrderType Picker Section
    private func orderTypePickerSection() -> some View {
        Picker("Order Type", selection: $orderType) {
            ForEach(OrderType.allCases, id: \.self) { type in
                Text(type.rawValue.capitalized).tag(type)
            }
        }
        .pickerStyle(SegmentedPickerStyle())
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 12)
    }

    // MARK: – Limit/Stop Price Section
    @ViewBuilder
    private func priceInputsSection() -> some View {
        if orderType == .limit {
            HStack(spacing: 8) {
                Text("Limit:")
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .fixedSize()
                TextField("0.0", text: $limitPrice)
                    .keyboardType(.decimalPad)
                    .foregroundColor(.white)
                    .padding(8)
                    .background(Color.white.opacity(0.1))
                    .cornerRadius(8)
                    .frame(width: 80)
            }
            .padding(.horizontal, 12)
        } else if orderType == .stopLimit {
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    Text("Stop:")
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .fixedSize()
                    TextField("0.0", text: $stopPrice)
                        .keyboardType(.decimalPad)
                        .foregroundColor(.white)
                        .padding(8)
                        .background(Color.white.opacity(0.1))
                        .cornerRadius(8)
                        .frame(width: 80)
                }
                HStack(spacing: 8) {
                    Text("Limit:")
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .fixedSize()
                    TextField("0.0", text: $limitPrice)
                        .keyboardType(.decimalPad)
                        .foregroundColor(.white)
                        .padding(8)
                        .background(Color.white.opacity(0.1))
                        .cornerRadius(8)
                        .frame(width: 80)
                }
            }
            .padding(.horizontal, 12)
        }
    }

    // MARK: – Quantity Controls Section
    private func quantityControlsSection() -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            let isCompact = horizontalSizeClass == .compact
            HStack(spacing: isCompact ? 4 : 8) {
                Button { vm.decrementQuantity(&quantity) } label: {
                    Image(systemName: "minus.circle")
                }
                .foregroundColor(.white)
                .padding(6)
                .background(Color.white.opacity(0.15))
                .cornerRadius(8)
                .buttonStyle(PressableButtonStyle())
                TextField("Quantity", text: $quantity)
                    .keyboardType(.decimalPad)
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)
                    .padding(.vertical, 6)
                    .padding(.horizontal, isCompact ? 12 : 16)
                    .background(Color.white.opacity(0.1))
                    .cornerRadius(8)
                    .frame(minWidth: isCompact ? 80 : 120)
                Button { vm.incrementQuantity(&quantity) } label: {
                    Image(systemName: "plus.circle")
                }
                .foregroundColor(.white)
                .padding(6)
                .background(Color.white.opacity(0.15))
                .cornerRadius(8)
                .fixedSize()
                .buttonStyle(PressableButtonStyle())
                ForEach([25, 50, 75, 100], id: \.self) { pct in
                    Button("\(pct)%") {
                        quantity = vm.fillQuantity(forPercent: pct)
                    }
                    .foregroundColor(.white)
                    .font(.caption2)
                    .padding(.vertical, isCompact ? 4 : 6)
                    .padding(.horizontal, isCompact ? 6 : 8)
                    .background(Color.white.opacity(0.15))
                    .cornerRadius(8)
                    .fixedSize()
                    .buttonStyle(PressableButtonStyle())
                }
                // Slippage button inserted here
                Button {
                    showSlippageDialog = true
                } label: {
                    Label("\(Int(slippageTolerance * 100))%", systemImage: "gearshape.fill")
                        .font(.caption2)
                        .foregroundColor(.white)
                        .padding(.vertical, 6)
                        .padding(.horizontal, isCompact ? 6 : 8)
                        .background(RoundedRectangle(cornerRadius: 12)
                            .fill(Color.black.opacity(0.2)))
                        .fixedSize()
                }
                .confirmationDialog("Select Slippage", isPresented: $showSlippageDialog) {
                    ForEach([0.1, 0.5, 1.0, 2.0], id: \.self) { pct in
                        Button("\(Int(pct * 100))%") { slippageTolerance = pct }
                    }
                }
            }
            .padding(.horizontal, isCompact ? 6 : 10)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: – Balance, Slippage, Bot Row Section
    private func balanceBotRowSection(balanceCrypto: Double, balanceUSD: Double) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            let isCompact = horizontalSizeClass == .compact
            HStack(alignment: .center, spacing: isCompact ? 6 : 12) {
                // Balance display
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(format: "Balance: %.4f %@", balanceCrypto, symbol.uppercased()))
                        .font(.caption)
                        .foregroundColor(.white)
                    Text("≈ \(formatPriceWithCommas(balanceUSD))")
                        .font(.caption)
                        .foregroundColor(.white)
                }
                Spacer()

                // Trading Bot button
                NavigationLink {
                    TradingBotView(side: selectedSide,
                                   orderType: orderType,
                                   quantity: Double(quantity) ?? 0.0,
                                   slippage: slippageTolerance)
                } label: {
                    Label("Trading Bot", systemImage: "cpu.fill")
                        .font(.caption2)
                        .foregroundColor(.black)
                        .padding(.vertical, 6)
                        .padding(.horizontal, isCompact ? 8 : 10)
                        .background(RoundedRectangle(cornerRadius: 12)
                            .fill(Color.yellow))
                        .fixedSize()
                }

                // Derivatives Bot button (restored icon and label)
                NavigationLink {
                    DerivativesBotView(
                        viewModel: DerivativesBotViewModel(),
                        isUSUser: ComplianceManager.shared.isUSUser
                    )
                } label: {
                    Label("Derivatives Bot", systemImage: "waveform.path.ecg")
                        .font(.caption2)
                        .foregroundColor(.black)
                        .padding(.vertical, 6)
                        .padding(.horizontal, isCompact ? 8 : 10)
                        .background(RoundedRectangle(cornerRadius: 12)
                            .fill(Color.yellow))
                        .fixedSize()
                }
            }
            .padding(.horizontal, isCompact ? 8 : 12)
        }
    }

    // MARK: – Slider Row Section
    private func sliderRowSection() -> some View {
        HStack {
            Slider(value: $sliderValue, in: 0...1, step: 0.01) {
                Text("Amount Slider")
            }
            .accentColor(.yellow)
            .onChange(of: sliderValue) { newVal, _ in
                let pct = Int(newVal * 100)
                quantity = vm.fillQuantity(forPercent: pct)
            }
        }
        .padding(.horizontal, 12)
    }

    // MARK: – Submit Button Section
    private func submitButtonSection() -> some View {
        Button {
            vm.executeTrade(side: selectedSide, symbol: symbol, orderType: orderType, quantity: quantity)
        } label: {
            Text("\(selectedSide.rawValue.capitalized) \(symbol.uppercased())")
                .font(.headline)
                .foregroundColor(selectedSide == .sell ? .white : .black)
                .padding()
                .frame(maxWidth: .infinity)
                .background(selectedSide == .sell ? Color.red : Color.yellow)
                .cornerRadius(12)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .disabled(
            quantity == "0.0"
            || (orderType == .limit && limitPrice.isEmpty)
            || (orderType == .stopLimit && (stopPrice.isEmpty || limitPrice.isEmpty))
        )
    }

    var body: some View {
        let qtyVal     = Double(quantity) ?? 0
        let tradeAmount = qtyVal * priceVM.price
        let fee        = tradeAmount * 0.001
        let totalCost  = tradeAmount + fee
        let balanceCrypto = vm.balance
        let balanceUSD = balanceCrypto * priceVM.price

        VStack(spacing: 8) {
            // Fee + Buy/Sell controls
            FeeCostSection(
                fee: fee,
                totalCost: totalCost,
                selectedSide: $selectedSide,
                slippageTolerance: $slippageTolerance,
                showSlippageDialog: $showSlippageDialog
            )

            orderTypePickerSection()
            priceInputsSection()
            quantityControlsSection()
            balanceBotRowSection(balanceCrypto: balanceCrypto, balanceUSD: balanceUSD)
            sliderRowSection()
            submitButtonSection()
        }
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.black.opacity(0.2))
        )
    }
}
    
    // MARK: - Order Book Depth List
    private var depthList: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Bid (\(orderBookVM.quoteCurrency))")
                    .font(.caption)
                    .foregroundColor(.green)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("Ask (\(orderBookVM.baseCurrency))")
                    .font(.caption)
                    .foregroundColor(.red)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(.horizontal, 12)
            GeometryReader { geometry in
                let colWidth = geometry.size.width * 0.45
                HStack(alignment: .top, spacing: 24) {
                    bidsColumn(width: colWidth)
                        .frame(width: colWidth, alignment: .leading)
                    asksColumn(width: colWidth)
                        .frame(width: colWidth, alignment: .leading)
                    Spacer()
                }
                .padding(.horizontal, 12)
            }
        }
        .frame(minHeight: 200)
        .padding(.vertical, 8)
        .background(Color.black.opacity(0.25))
        .cornerRadius(8)
        .redacted(reason: (!hasLoadedOrderBook && orderBookVM.isLoading) ? .placeholder : [])
        .animation(.easeInOut, value: orderBookVM.isLoading)
    }


    // MARK: - Order Book Section
    private var orderBookSection: some View {
        VStack(spacing: 8) {
            depthList
        }
        .onChange(of: orderBookVM.bids) { newBids in
            if !hasLoadedOrderBook {
                hasLoadedOrderBook = true
            }
            let topEntries = newBids.prefix(5)
            // Highlight entries whose qty changed or are new
            let changedPrices = topEntries.compactMap { entry in
                if let oldQty = previousBidMap[entry.price] {
                    return oldQty != entry.qty ? entry.price : nil
                } else {
                    return entry.price
                }
            }
            highlightedBids = Set(changedPrices)
            // Update map for next diff
            previousBidMap = Dictionary(uniqueKeysWithValues: topEntries.map { ($0.price, $0.qty) })
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                highlightedBids.removeAll()
            }
        }
        .onChange(of: orderBookVM.asks) { newAsks in
            let topEntries = newAsks.prefix(5)
            let changedPrices = topEntries.compactMap { entry in
                if let oldQty = previousAskMap[entry.price] {
                    return oldQty != entry.qty ? entry.price : nil
                } else {
                    return entry.price
                }
            }
            highlightedAsks = Set(changedPrices)
            previousAskMap = Dictionary(uniqueKeysWithValues: topEntries.map { ($0.price, $0.qty) })
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                highlightedAsks.removeAll()
            }
        }
    }
}

// MARK: - EnhancedCoinPickerView
struct EnhancedCoinPickerView: View {
    @Environment(\.presentationMode) var presentationMode
    
    @Binding var currentSymbol: String
    var onSelect: (String) -> Void
    
    @State private var allCoins: [Coin] = [
        Coin(symbol: "BTC", name: "Bitcoin"),
        Coin(symbol: "ETH", name: "Ethereum"),
        Coin(symbol: "SOL", name: "Solana"),
        Coin(symbol: "ADA", name: "Cardano"),
        Coin(symbol: "XRP", name: "XRP"),
        Coin(symbol: "BNB", name: "Binance Coin"),
        Coin(symbol: "MATIC", name: "Polygon"),
        Coin(symbol: "DOT", name: "Polkadot"),
        Coin(symbol: "DOGE", name: "Dogecoin"),
        Coin(symbol: "SHIB", name: "Shiba Inu"),
        Coin(symbol: "RLC", name: "iExec RLC")
    ]
    
    @State private var searchText: String = ""
    
    var filteredCoins: [Coin] {
        if searchText.isEmpty { return allCoins }
        return allCoins.filter {
            $0.symbol.localizedCaseInsensitiveContains(searchText)
            || $0.name.localizedCaseInsensitiveContains(searchText)
        }
    }
    
    var body: some View {
        NavigationView {
            ZStack {
                Color.black.ignoresSafeArea()
                
                VStack(spacing: 0) {
                    // Search bar
                    HStack {
                        Image(systemName: "magnifyingglass")
                            .foregroundColor(.gray)
                        TextField("Search coins", text: $searchText)
                            .foregroundColor(.white)
                    }
                    .padding(8)
                    .background(Color.white.opacity(0.1))
                    .cornerRadius(10)
                    .padding(.horizontal)
                    .padding(.top, 8)
                    
                    // List of coins
                    List {
                        ForEach(filteredCoins) { coin in
                            Button {
                                currentSymbol = coin.symbol
                                onSelect(coin.symbol)
                                presentationMode.wrappedValue.dismiss()
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(coin.symbol)
                                            .foregroundColor(.white)
                                            .font(.headline)
                                        Text(coin.name)
                                            .foregroundColor(.gray)
                                            .font(.caption)
                                    }
                                    Spacer()
                                    if coin.symbol == currentSymbol {
                                        Image(systemName: "checkmark")
                                            .foregroundColor(.yellow)
                                    }
                                }
                            }
                            .listRowBackground(Color.clear)
                        }
                    }
                    .scrollContentBackground(.hidden)
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Select Coin")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Close") {
                        presentationMode.wrappedValue.dismiss()
                    }
                    .foregroundColor(.yellow)
                }
            }
        }
        .accentColor(.yellow)
    }
}

// MARK: - Coin Model
struct Coin: Identifiable {
    let id = UUID()
    let symbol: String
    let name: String
}

// --------------------------------------------------------------------------
// REMOVED local RenamePaymentMethodView to avoid conflict with PaymentMethodsView.swift
// --------------------------------------------------------------------------

// MARK: - TradeViewModel

// MARK: - OrderBookViewModel
class OrderBookViewModel: ObservableObject {
    @Published var currentSymbol: String = ""
    struct OrderBookEntry: Equatable, Codable {
        let price: String
        let qty: String
    }
    
    // MARK: - Order Book Caching Helpers
    private func cacheKeys(for symbol: String) -> (bidsKey: String, asksKey: String) {
        let base = "OrderBookCache_\(symbol)"
        return ("\(base)_bids", "\(base)_asks")
    }

    private func loadCache(for symbol: String) {
        let keys = cacheKeys(for: symbol)
        let decoder = JSONDecoder()
        if let data = UserDefaults.standard.data(forKey: keys.bidsKey),
           let cached = try? decoder.decode([OrderBookEntry].self, from: data) {
            bids = cached
        }
        if let data = UserDefaults.standard.data(forKey: keys.asksKey),
           let cached = try? decoder.decode([OrderBookEntry].self, from: data) {
            asks = cached
        }
    }

    private func saveCache(for symbol: String) {
        let keys = cacheKeys(for: symbol)
        let encoder = JSONEncoder()
        if let data = try? encoder.encode(bids) {
            UserDefaults.standard.set(data, forKey: keys.bidsKey)
        }
        if let data = try? encoder.encode(asks) {
            UserDefaults.standard.set(data, forKey: keys.asksKey)
        }
    }
    
    @Published var bids: [OrderBookEntry] = []
    @Published var asks: [OrderBookEntry] = []
    @Published var isLoading: Bool = false
    @Published var errorMessage: String? = nil
    
    private var timer: Timer?
    
    func startFetchingOrderBook(for symbol: String) {
        self.currentSymbol = symbol
        let pair = symbol.uppercased() + "-USD"
        loadCache(for: symbol)
        fetchOrderBook(pair: pair)
        
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
            self.fetchOrderBook(pair: pair)
        }
    }
    
    func stopFetching() {
        timer?.invalidate()
        timer = nil
    }
    
    private func fetchOrderBook(pair: String) {
        let urlString = "https://api.exchange.coinbase.com/products/\(pair)/book?level=2"
        guard let url = URL(string: urlString) else {
            DispatchQueue.main.async {
                self.errorMessage = "Invalid order book URL."
            }
            return
        }
        DispatchQueue.main.async {
            self.isLoading = true
            self.errorMessage = nil
        }
        
        URLSession.shared.dataTask(with: url) { data, _, error in
            DispatchQueue.main.async { self.isLoading = false }
            if let error = error {
                print("Coinbase order book error:", error.localizedDescription)
                self.fallbackFetchOrderBook(pair: pair)
                return
            }
            guard let data = data else {
                print("No data from Coinbase order book.")
                self.fallbackFetchOrderBook(pair: pair)
                return
            }
            do {
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let bidsArr = json["bids"] as? [[Any]],
                   let asksArr = json["asks"] as? [[Any]] {
                    
                    let parsedBids = bidsArr.map { arr -> OrderBookEntry in
                        let price = arr[0] as? String ?? "0"
                        let qty   = arr[1] as? String ?? "0"
                        return OrderBookEntry(price: price, qty: qty)
                    }
                    let parsedAsks = asksArr.map { arr -> OrderBookEntry in
                        let price = arr[0] as? String ?? "0"
                        let qty   = arr[1] as? String ?? "0"
                        return OrderBookEntry(price: price, qty: qty)
                    }
                    DispatchQueue.main.async {
                        self.bids = parsedBids
                        self.asks = parsedAsks
                        self.saveCache(for: pair.replacingOccurrences(of: "-USD", with: ""))
                    }
                } else {
                    print("Coinbase order book parse error, falling back.")
                    self.fallbackFetchOrderBook(pair: pair)
                    return
                }
            } catch {
                print("Coinbase order book JSON parse error:", error.localizedDescription)
                self.fallbackFetchOrderBook(pair: pair)
                return
            }
        }.resume()
    }

    // MARK: - Fallback Order Book Fetch
    private func fallbackFetchOrderBook(pair: String) {
        // Clear previous error and set loading state at the very beginning
        DispatchQueue.main.async {
            self.isLoading = true
            self.errorMessage = nil
        }
        // Use Binance API as fallback
        // Convert pair like "BTC-USD" to "BTCUSD"
        let symbolOnly = pair.replacingOccurrences(of: "-USD", with: "")
        let urlString = "https://api.binance.com/api/v3/depth?symbol=\(symbolOnly)USDT&limit=20"
        guard let url = URL(string: urlString) else {
            DispatchQueue.main.async {
                self.isLoading = false
                self.errorMessage = "Invalid Binance order book URL."
            }
            return
        }
        URLSession.shared.dataTask(with: url) { data, _, error in
            DispatchQueue.main.async { self.isLoading = false }
            if let error = error {
                print("Binance order book error:", error.localizedDescription)
                DispatchQueue.main.async {
                    self.errorMessage = "Error loading order book."
                }
                return
            }
            guard let data = data else {
                print("No data from Binance order book.")
                DispatchQueue.main.async {
                    self.errorMessage = "Error loading order book."
                }
                return
            }
            do {
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let bidsArr = json["bids"] as? [[Any]],
                   let asksArr = json["asks"] as? [[Any]] {
                    let parsedBids = bidsArr.map { arr -> OrderBookEntry in
                        let price = arr[0] as? String ?? "0"
                        let qty   = arr[1] as? String ?? "0"
                        return OrderBookEntry(price: price, qty: qty)
                    }
                    let parsedAsks = asksArr.map { arr -> OrderBookEntry in
                        let price = arr[0] as? String ?? "0"
                        let qty   = arr[1] as? String ?? "0"
                        return OrderBookEntry(price: price, qty: qty)
                    }
                    DispatchQueue.main.async {
                        self.errorMessage = nil
                        self.bids = parsedBids
                        self.asks = parsedAsks
                        self.saveCache(for: pair.replacingOccurrences(of: "-USD", with: ""))
                    }
                } else {
                    DispatchQueue.main.async {
                        self.errorMessage = "Error loading order book."
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.errorMessage = "Error loading order book."
                }
            }
        }.resume()
    }
}

// MARK: - OrderBookViewModel (add base/quote currency properties)
extension OrderBookViewModel {
    var baseCurrency: String {
        // Use the symbol that was set when fetching began, uppercased
        return currentSymbol.uppercased()
    }
    var quoteCurrency: String {
        // Always USD for Coinbase, or USDT for Binance fallback
        return "USD"
    }
}
