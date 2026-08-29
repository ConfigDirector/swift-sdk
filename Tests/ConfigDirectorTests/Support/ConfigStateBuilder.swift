@testable import ConfigDirector

extension ConfigState {
    static func make(
        key: String,
        type: ConfigType,
        value: String?,
        valueID: String? = nil
    ) -> ConfigState {
        ConfigState(id: key, key: key, type: type, value: value, valueID: valueID)
    }
}
