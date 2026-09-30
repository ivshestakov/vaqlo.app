import Accelerate

/// Офлайн-подавление эха в дорожке микрофона. Когда звонок идёт через динамики, микрофон
/// ловит собеседников второй раз — в плеере это звучит как эхо, а в транскрипте как чужие
/// реплики под «моим» именем. Опорный сигнал у нас есть точный: системная дорожка — это
/// ровно то, что ушло в динамики.
///
/// Схема (запись уже закончена, поэтому причинность не нужна):
/// 1. Грубая задержка mic относительно системного звука — GCC-PHAT по окнам 10 с.
///    Покрывает и акустику + задержку вывода (десятки мс, у Bluetooth — сотни),
///    и рассинхрон старых записей, где начала чанков округлены до секунды.
/// 2. Линейный адаптивный фильтр в частотной области (блочный NLMS с разбиением на
///    партиции, PBFDAF) моделирует путь «динамик → комната → микрофон» и вычитает эхо.
/// 3. Спектральное подавление остатка там, где оценка эха сравнима с остатком.
///
/// Параметры подобраны на реальных созвонах (динамики MacBook Air): чужая речь в
/// микрофоне ослабляется на ~25 дБ, свой голос без собеседников не трогается, при
/// одновременной речи приглушается на 5–7 дБ.
enum EchoCanceller {
    struct Result {
        let samples: [Float]
        /// Задержка эха в микрофоне относительно опорного сигнала, секунды.
        let delay: Double
    }

    /// `mic` и `reference` — моно, одна частота, общая шкала времени (±1,5 с допустимо).
    /// nil — эха не найдено (наушники, собеседники молчали) или фильтр не справился:
    /// тогда дорожку лучше оставить как есть.
    static func process(mic: [Float], reference: [Float], sampleRate: Double) -> Result? {
        let n = min(mic.count, reference.count)
        guard n > Int(sampleRate * 5) else { return nil }
        let mic = Array(mic[0..<n])
        guard let lag = bulkDelay(mic: mic, reference: Array(reference[0..<n]), sampleRate: sampleRate) else {
            return nil
        }
        // Сдвигаем опорный сигнал так, чтобы он опережал эхо на 10 мс: фильтру нужен
        // небольшой запас на «предзвон» пути.
        let shift = lag - Int(sampleRate * 0.01)
        var ref = [Float](repeating: 0, count: n)
        if shift >= 0 {
            for i in shift..<n { ref[i] = reference[i - shift] }
        } else {
            for i in 0..<(n + shift) { ref[i] = reference[i - shift] }
        }

        let filter = AdaptiveFilter(blockSize: 512, partitions: 16)
        // Прогрев: фильтр стартует с нуля, и без него начало каждого чанка осталось бы с эхом.
        _ = filter.run(mic: mic, reference: ref, limit: min(n, Int(sampleRate * 30)))
        filter.resetHistory()
        let (residual, echo) = filter.run(mic: mic, reference: ref, limit: n)
        var out = suppressResidual(residual: residual, echo: echo)
        out += mic[out.count..<n]  // хвост короче блока — как есть

        // Страховка от расходимости: результат не может быть громче исходника.
        guard energy(out) <= energy(mic) * 1.2 else { return nil }
        return Result(samples: out, delay: Double(lag) / sampleRate)
    }

    private static func energy(_ x: [Float]) -> Float {
        var e: Float = 0
        vDSP_svesq(x, 1, &e, vDSP_Length(x.count))
        return e
    }

    // MARK: - Грубая задержка

    /// Задержка эха (в сэмплах, >0 — микрофон отстаёт) по медиане уверенных окон.
    static func bulkDelay(mic: [Float], reference: [Float], sampleRate: Double) -> Int? {
        let decim = max(1, Int(sampleRate / 8000))
        let rate = sampleRate / Double(decim)
        let m = decimate(mic, by: decim)
        let r = decimate(reference, by: decim)
        let window = Int(rate * 10)
        let maxLag = Int(rate * 1.5)
        var size = 1
        while size < 2 * window + 2 * maxLag { size <<= 1 }
        guard let fft = RealFFT(size: size) else { return nil }

        var lags: [Int] = []
        var start = maxLag
        while start + window + maxLag <= m.count {
            defer { start += window }
            let x = Array(r[start..<(start + window)])
            var power: Float = 0
            vDSP_measqv(x, 1, &power, vDSP_Length(x.count))
            guard power > 1e-6 else { continue }  // собеседники молчат — окно бесполезно
            let y = Array(m[(start - maxLag)..<(start + window + maxLag)])

            var (xr, xi) = fft.forward(x)
            let (yr, yi) = fft.forward(y)
            // Взаимный спектр Y·conj(X), нормированный по модулю (PHAT) — острый пик задержки.
            for k in 0..<xr.count {
                let re = yr[k] * xr[k] + yi[k] * xi[k]
                let im = yi[k] * xr[k] - yr[k] * xi[k]
                let mag = (re * re + im * im).squareRoot() + 1e-12
                xr[k] = re / mag
                xi[k] = im / mag
            }
            let corr = fft.inverse(xr, xi)
            let span = Array(corr[0...(2 * maxLag)]).map(abs)
            var peak: Float = 0
            var index: vDSP_Length = 0
            vDSP_maxvi(span, 1, &peak, &index, vDSP_Length(span.count))
            let median = span.sorted()[span.count / 2]
            if peak > 5 * median { lags.append(Int(index) - maxLag) }
        }
        guard lags.count >= 3 else { return nil }
        return lags.sorted()[lags.count / 2] * decim
    }

    private static func decimate(_ x: [Float], by factor: Int) -> [Float] {
        guard factor > 1 else { return x }
        let count = x.count / factor
        var out = [Float](repeating: 0, count: count)
        // Усреднение по `factor` сэмплов — грубый ФНЧ, для поиска задержки его хватает.
        let kernel = [Float](repeating: 1 / Float(factor), count: factor)
        vDSP_desamp(x, vDSP_Stride(factor), kernel, &out, vDSP_Length(count), vDSP_Length(factor))
        return out
    }

    // MARK: - Подавление остатка

    /// STFT (окно √Ханна, перекрытие 50%): гасим бины, где оценка эха сравнима с остатком.
    private static func suppressResidual(residual e: [Float], echo y: [Float]) -> [Float] {
        let hop = 512, size = 1024, bins = size / 2
        let fft = RealFFT(size: size)!
        let window = (0..<size).map { Float(sin(Double.pi * Double($0) / Double(size))) }  // √Ханн
        var out = [Float](repeating: 0, count: e.count)
        var pe = [Float](repeating: 0, count: bins), py = [Float](repeating: 0, count: bins)
        var first = true
        var frame = [Float](repeating: 0, count: size)
        var start = 0
        while start + size <= e.count {
            defer { start += hop }
            vDSP_vmul(Array(e[start..<(start + size)]), 1, window, 1, &frame, 1, vDSP_Length(size))
            var (er, ei) = fft.forward(frame)
            vDSP_vmul(Array(y[start..<(start + size)]), 1, window, 1, &frame, 1, vDSP_Length(size))
            let (yr, yi) = fft.forward(frame)
            for k in 0..<bins {
                let ce = er[k] * er[k] + ei[k] * ei[k]
                let cy = yr[k] * yr[k] + yi[k] * yi[k]
                if first { pe[k] = ce; py[k] = cy } else { pe[k] = 0.6 * pe[k] + 0.4 * ce; py[k] = 0.6 * py[k] + 0.4 * cy }
                let gain = min(1, max(0.05, 1 - 2 * py[k] / (pe[k] + 1e-12)))
                er[k] *= gain
                ei[k] *= gain
            }
            first = false
            let t = fft.inverse(er, ei)
            for i in 0..<size { out[start + i] += t[i] * window[i] }
        }
        return out
    }
}

/// Блочный NLMS в частотной области с разбиением фильтра на партиции (overlap-save,
/// градиент с ограничением на причинность). Длина пути = blockSize × partitions сэмплов
/// (512 × 16 ≈ 170 мс на 48 кГц) — хватает на реверберацию комнаты после компенсации задержки.
private final class AdaptiveFilter {
    private let block: Int
    private let partitions: Int
    private let bins: Int
    private let fft: RealFFT
    private let mu: Float = 0.3
    private let regularization: Float

    // Веса и история спектров опорного сигнала: [partition * bins + k].
    private var wr: [Float], wi: [Float]
    private var xr: [Float], xi: [Float]
    private var head = 0
    private var power: [Float]
    private var previous: [Float]

    init(blockSize: Int, partitions: Int) {
        block = blockSize
        self.partitions = partitions
        bins = blockSize  // упакованный спектр размера 2·block: bins = block
        fft = RealFFT(size: 2 * blockSize)!
        let n = Float(2 * blockSize)
        // Абсолютный порог мощности: без него тихий опорный сигнал (шум между фразами)
        // даёт гигантский шаг, и своя речь «разгоняет» фильтр до расходимости.
        regularization = Float(partitions) * n * n * 1e-6
        wr = .init(repeating: 0, count: partitions * blockSize); wi = wr
        xr = wr; xi = wr
        power = .init(repeating: 0, count: blockSize)
        previous = .init(repeating: 0, count: blockSize)
    }

    func resetHistory() {
        for i in 0..<xr.count { xr[i] = 0; xi[i] = 0 }
        for i in 0..<block { power[i] = 0; previous[i] = 0 }
    }

    /// Возвращает (остаток после вычитания эха, оценку эха) для первых `limit` сэмплов,
    /// округлённых вниз до блока.
    func run(mic: [Float], reference: [Float], limit: Int) -> ([Float], [Float]) {
        let blocks = limit / block
        let size = 2 * block
        var residual = [Float](repeating: 0, count: blocks * block)
        var echo = residual
        // Рабочие буферы — один раз на прогон: внутренний цикл без аллокаций.
        let frame = UnsafeMutablePointer<Float>.allocate(capacity: size)
        let time = UnsafeMutablePointer<Float>.allocate(capacity: size)
        let yr = UnsafeMutablePointer<Float>.allocate(capacity: bins), yi = UnsafeMutablePointer<Float>.allocate(capacity: bins)
        let er = UnsafeMutablePointer<Float>.allocate(capacity: bins), ei = UnsafeMutablePointer<Float>.allocate(capacity: bins)
        let gr = UnsafeMutablePointer<Float>.allocate(capacity: bins), gi = UnsafeMutablePointer<Float>.allocate(capacity: bins)
        let sumPower = UnsafeMutablePointer<Float>.allocate(capacity: bins)
        defer { [frame, time, yr, yi, er, ei, gr, gi, sumPower].forEach { $0.deallocate() } }

        mic.withUnsafeBufferPointer { micP in
        reference.withUnsafeBufferPointer { refP in
        residual.withUnsafeMutableBufferPointer { resP in
        echo.withUnsafeMutableBufferPointer { echoP in
        wr.withUnsafeMutableBufferPointer { wrP in
        wi.withUnsafeMutableBufferPointer { wiP in
        xr.withUnsafeMutableBufferPointer { xrP in
        xi.withUnsafeMutableBufferPointer { xiP in
        power.withUnsafeMutableBufferPointer { powP in
        previous.withUnsafeMutableBufferPointer { prevP in
            let wr = wrP.baseAddress!, wi = wiP.baseAddress!, xr = xrP.baseAddress!, xi = xiP.baseAddress!
            let power = powP.baseAddress!, prev = prevP.baseAddress!
            for b in 0..<blocks {
                let base = b * block
                // Кадр overlap-save: [предыдущий блок, текущий блок] опорного сигнала.
                frame.update(from: prev, count: block)
                (frame + block).update(from: refP.baseAddress! + base, count: block)
                prev.update(from: refP.baseAddress! + base, count: block)

                head = (head + partitions - 1) % partitions
                fft.forward(frame, xr + head * bins, xi + head * bins)

                // Оценка эха: Σ W_p · X_{t-p}.
                for k in 0..<bins { yr[k] = 0; yi[k] = 0; sumPower[k] = 0 }
                for p in 0..<partitions {
                    let w1 = wr + p * bins, w2 = wi + p * bins
                    let o = ((head + p) % partitions) * bins
                    let x1 = xr + o, x2 = xi + o
                    for k in 0..<bins {
                        let a = w1[k], c = w2[k], x = x1[k], z = x2[k]
                        yr[k] += a * x - c * z
                        yi[k] += a * z + c * x
                        sumPower[k] += x * x + z * z
                    }
                }
                fft.inverse(yr, yi, time)
                for i in 0..<block {
                    let estimate = time[block + i]
                    echoP[base + i] = estimate
                    resP[base + i] = micP[base + i] - estimate
                }

                // Градиент: E = FFT([0…0, e]), шаг нормирован на мощность опоры по всем партициям.
                for i in 0..<block { frame[i] = 0; frame[block + i] = resP[base + i] }
                fft.forward(frame, er, ei)
                for k in 0..<bins {
                    power[k] = 0.7 * power[k] + 0.3 * sumPower[k]
                    let step = mu / (power[k] + regularization)
                    er[k] *= step
                    ei[k] *= step
                }
                for p in 0..<partitions {
                    let o = ((head + p) % partitions) * bins
                    let x1 = xr + o, x2 = xi + o
                    for k in 0..<bins {  // conj(X) · E
                        let x = x1[k], z = x2[k]
                        gr[k] = x * er[k] + z * ei[k]
                        gi[k] = x * ei[k] - z * er[k]
                    }
                    // Ограничение причинности: вторая половина импульсной характеристики — ноль.
                    fft.inverse(gr, gi, time)
                    for i in block..<size { time[i] = 0 }
                    fft.forward(time, gr, gi)
                    vDSP_vadd(wr + p * bins, 1, gr, 1, wr + p * bins, 1, vDSP_Length(bins))
                    vDSP_vadd(wi + p * bins, 1, gi, 1, wi + p * bins, 1, vDSP_Length(bins))
                }
            }
        }}}}}}}}}}
        return (residual, echo)
    }
}

/// Вещественное БПФ через vDSP в масштабе numpy: forward = rfft, inverse = irfft.
/// Спектр упакован в size/2 бинов; бин Найквиста отбрасывается (imag[0] = 0) —
/// так все поэлементные комплексные операции корректны и для DC.
final class RealFFT {
    let size: Int
    private let forwardSetup: vDSP_DFT_Setup
    private let inverseSetup: vDSP_DFT_Setup
    private var evens: [Float], odds: [Float]

    init?(size: Int) {
        guard let f = vDSP_DFT_zrop_CreateSetup(nil, vDSP_Length(size), .FORWARD),
              let i = vDSP_DFT_zrop_CreateSetup(f, vDSP_Length(size), .INVERSE) else { return nil }
        self.size = size
        forwardSetup = f
        inverseSetup = i
        evens = .init(repeating: 0, count: size / 2)
        odds = evens
    }

    deinit {
        vDSP_DFT_DestroySetup(forwardSetup)
        vDSP_DFT_DestroySetup(inverseSetup)
    }

    /// `signal` — ровно `size` сэмплов; спектр пишется в `re`/`im` (по size/2).
    func forward(_ signal: UnsafePointer<Float>, _ re: UnsafeMutablePointer<Float>, _ im: UnsafeMutablePointer<Float>) {
        let half = size / 2
        evens.withUnsafeMutableBufferPointer { e in
            odds.withUnsafeMutableBufferPointer { o in
                var split = DSPSplitComplex(realp: e.baseAddress!, imagp: o.baseAddress!)
                signal.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                    vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
                }
                vDSP_DFT_Execute(forwardSetup, e.baseAddress!, o.baseAddress!, re, im)
            }
        }
        var scale: Float = 0.5  // vDSP даёт 2× относительно математического ДПФ
        vDSP_vsmul(re, 1, &scale, re, 1, vDSP_Length(half))
        vDSP_vsmul(im, 1, &scale, im, 1, vDSP_Length(half))
        im[0] = 0
    }

    /// Результат (`size` сэмплов) пишется в `out`. `im[0]` обнуляется.
    func inverse(_ re: UnsafePointer<Float>, _ im: UnsafeMutablePointer<Float>, _ out: UnsafeMutablePointer<Float>) {
        let half = size / 2
        im[0] = 0
        evens.withUnsafeMutableBufferPointer { e in
            odds.withUnsafeMutableBufferPointer { o in
                vDSP_DFT_Execute(inverseSetup, re, im, e.baseAddress!, o.baseAddress!)
                var split = DSPSplitComplex(realp: e.baseAddress!, imagp: o.baseAddress!)
                out.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                    vDSP_ztoc(&split, 1, $0, 2, vDSP_Length(half))
                }
            }
        }
        var scale = 1 / Float(size)
        vDSP_vsmul(out, 1, &scale, out, 1, vDSP_Length(size))
    }

    /// Удобные варианты с массивами (вход дополняется нулями до `size`).
    func forward(_ signal: [Float]) -> ([Float], [Float]) {
        var padded = signal.count == size ? signal : Array(signal.prefix(size)) + [Float](repeating: 0, count: max(0, size - signal.count))
        var re = [Float](repeating: 0, count: size / 2), im = re
        padded.withUnsafeMutableBufferPointer { s in
            re.withUnsafeMutableBufferPointer { r in
                im.withUnsafeMutableBufferPointer { i in forward(s.baseAddress!, r.baseAddress!, i.baseAddress!) }
            }
        }
        return (re, im)
    }

    func inverse(_ re: [Float], _ im: [Float]) -> [Float] {
        var im = im
        var out = [Float](repeating: 0, count: size)
        re.withUnsafeBufferPointer { r in
            im.withUnsafeMutableBufferPointer { i in
                out.withUnsafeMutableBufferPointer { o in inverse(r.baseAddress!, i.baseAddress!, o.baseAddress!) }
            }
        }
        return out
    }
}
