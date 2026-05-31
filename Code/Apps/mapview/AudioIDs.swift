import DuneIIContracts

/// The sounds this viewer plays for player feedback (mapped to install VOCs in `MapModel`). A small set for
/// the first audio pass — enough to hear the low-latency, multi-playable mixing on rapid clicks/orders.
extension SoundID {
    static let select = SoundID(0)        // CLICK.VOC — a unit/building was selected
    static let acknowledge = SoundID(1)   // AFFIRM.VOC — an order was issued
}
