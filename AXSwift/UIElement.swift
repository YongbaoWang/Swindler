/// Holds and interacts with any accessibility element.
///
/// This class wraps every operation that operates on AXUIElements.
///
/// - seeAlso: [OS X Accessibility Model](https://developer.apple.com/library/mac/documentation/Accessibility/Conceptual/AccessibilityMacOSX/OSXAXmodel.html)
///
/// Note that every operation involves IPC and is tied to the event loop of the target process. This
/// means that operations are synchronous and can hang until they time out. The default timeout is
/// 6 seconds, but it can be changed using `setMessagingTimeout` and `setGlobalMessagingTimeout`.
///
/// Every attribute- or action-related function has an enum version and a String version. This is
/// because certain processes might report attributes or actions not documented in the standard API.
/// These will be ignored by enum functions (and you can't specify them). Most users will want to
/// use the enum-based versions, but if you want to be exhaustive or use non-standard attributes and
/// actions, you can use the String versions.
///
/// ### Error handling
///
/// Unless otherwise specified, during reads, "missing data/attribute" errors are handled by
/// returning optionals as nil. During writes, missing attribute errors are thrown.
///
/// Other failures are all thrown, including if messaging fails or the underlying AXUIElement
/// becomes invalid.
///
/// #### Possible Errors
/// - `Error.APIDisabled`: The accessibility API is disabled. Your application must request and
///                        receive special permission from the user to be able to use these APIs.
/// - `Error.InvalidUIElement`: The UI element has become invalid, perhaps because it was destroyed.
/// - `Error.CannotComplete`: There is a problem with messaging, perhaps because the application is
///                           being unresponsive. This error will be thrown when a message times out.
/// - `Error.NotImplemented`: The process does not fully support the accessibility API.
/// - Anything included in the docs of the method you are calling.
///
/// Any undocumented errors thrown are bugs and should be reported.
///
/// - seeAlso: [AXUIElement.h reference](https://developer.apple.com/library/mac/documentation/ApplicationServices/Reference/AXUIElement_header_reference/)
public class UIElement {
  let element: AXUIElement

  init(_ nativeElement: AXUIElement) {
    // Since we are dealing with low-level C APIs, it never hurts to double check types.
    assert(CFGetTypeID(nativeElement) == AXUIElementGetTypeID(), "nativeElement is not an AXUIElement")

    element = nativeElement
  }

  /// Checks if the current process is a trusted accessibility client. If false, all APIs will throw
  /// errors.
  ///
  /// - parameter withPrompt: Whether to show the user a prompt if the process is untrusted. This
  ///                         happens asynchronously and does not affect the return value.
  public class func isProcessTrusted(withPrompt showPrompt: Bool = false) -> Bool {
    let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: showPrompt as CFBoolean]
    return AXIsProcessTrustedWithOptions(options)
  }

  /// Timeout in seconds for all UIElement messages. Use this to control how long a method call can
  /// delay execution. The default is `0` which means to use the system default.
  public var globalMessagingTimeout: Float {
    get { return systemWideElement.messagingTimeout }
    set { systemWideElement.messagingTimeout = newValue }
  }

  // MARK: - Attributes

  /// Returns the list of all attributes.
  ///
  /// Does not include parameterized attributes.
  public func attributes() throws -> [Attribute] {
    let attrs = try attributesAsStrings()
    for attr in attrs where Attribute(rawValue: attr) == nil { print("Unrecognized attribute: \(attr)") }
    return attrs.flatMap({ Attribute(rawValue: $0) })
  }

  // This version is named differently so the caller doesn't have to specify the return type when
  // using the enum version.
  public func attributesAsStrings() throws -> [String] {
    var names: CFArray?
    let error = AXUIElementCopyAttributeNames(element, &names)

    if error == .NoValue || error == .AttributeUnsupported {
      return []
    }

    guard error == .Success else {
      throw error
    }

    // We must first convert the CFArray to a native array, then downcast to an array of strings.
    return names! as [AnyObject] as! [String]
  }

  /// Returns whether `attribute` is supported by this element.
  ///
  /// The `attribute` method returns nil for unsupported attributes and empty attributes alike,
  /// which is more convenient than dealing with exceptions (which are used for more serious
  /// errors). However, if you'd like to specifically test an attribute is actually supported, you
  /// can use this method.
  public func attributeIsSupported(attribute: Attribute) throws -> Bool {
    return try attributeIsSupported(attribute.rawValue)
  }

  public func attributeIsSupported(attribute: String) throws -> Bool {
    // Ask to copy 0 values, since we are only interested in the return code.
    var value: CFArray?
    let error = AXUIElementCopyAttributeValues(element, attribute, 0, 0, &value)

    if error == .AttributeUnsupported {
      return false
    }

    if error == .NoValue {
      return true
    }

    guard error == .Success else {
      throw error
    }

    return true
  }

  /// Returns whether `attribute` is writeable.
  public func attributeIsSettable(attribute: Attribute) throws -> Bool {
    return try attributeIsSettable(attribute.rawValue)
  }

  public func attributeIsSettable(attribute: String) throws -> Bool {
    var settable: DarwinBoolean = false
    let error = AXUIElementIsAttributeSettable(element, attribute, &settable)

    if error == .NoValue || error == .AttributeUnsupported {
      return false
    }

    guard error == .Success else {
      throw error
    }

    return settable.boolValue
  }

  /// Returns the value of `attribute`, if it exists.
  ///
  /// - parameter attribute: The name of a (non-parameterized) attribute.
  ///
  /// - returns: An optional containing the value of `attribute` as the desired type, or nil.
  ///            If `attribute` is an array, all values are returned.
  ///
  /// - warning: This method force-casts the attribute to the desired type, which will abort if the
  ///            cast fails. If you want to check the return type, ask for AnyObject.
  public func attribute<T>(attribute: Attribute) throws -> T? {
    return try self.attribute(attribute.rawValue)
  }

  public func attribute<T>(attribute: String) throws -> T? {
    var value: AnyObject?
    let error = AXUIElementCopyAttributeValue(element, attribute, &value)

    if error == .NoValue || error == .AttributeUnsupported {
      return nil
    }

    guard error == .Success else {
      throw error
    }

    return (unpackAXValue(value!) as! T)
  }

  // Checks if the value is an AXValue and if so, unwraps it.
  private func unpackAXValue(value: AnyObject) -> Any {
    guard CFGetTypeID(value) == AXValueGetTypeID() else {
      return value
    }

    let type = AXValueGetType(value as! AXValue)
    switch type {
    case .AXError:
      var result: AXError = .Success
      let success = AXValueGetValue(value as! AXValue, type, &result)
      assert(success)
      return result
    case .CFRange:
      var result: CFRange = CFRange()
      let success = AXValueGetValue(value as! AXValue, type, &result)
      assert(success)
      return result
    case .CGPoint:
      var result: CGPoint = CGPointZero
      let success = AXValueGetValue(value as! AXValue, type, &result)
      assert(success)
      return result
    case .CGRect:
      var result: CGRect = CGRectZero
      let success = AXValueGetValue(value as! AXValue, type, &result)
      assert(success)
      return result
    case .CGSize:
      var result: CGSize = CGSizeZero
      let success = AXValueGetValue(value as! AXValue, type, &result)
      assert(success)
      return result
    case .Illegal:
      return value
    }
  }

  /// Sets the value of `attribute` to `value`.
  ///
  /// - warning: Unlike read-only methods, this method throws if the attribute doesn't exist.
  ///
  /// - throws:
  ///   - `Error.AttributeUnsupported` if `attribute` isn't supported,
  ///   - `Error.IllegalArgument` if `value` is an illegal value
  public func setAttribute(attribute: Attribute, value: Any) throws {
    try self.setAttribute(attribute.rawValue, value: value)
  }

  public func setAttribute(attribute: String, value: Any) throws {
    let error = AXUIElementSetAttributeValue(element, attribute, packAXValue(value))

    guard error == .Success else {
      throw error
    }
  }

  // Checks if the value is one supported by AXValue and if so, wraps it.
  private func packAXValue(value: Any) -> AnyObject {
    switch value {
    case var val as CFRange:
      return AXValueCreate(AXValueType(rawValue: kAXValueCFRangeType)!, &val)!.takeRetainedValue()
    case var val as CGPoint:
      return AXValueCreate(AXValueType(rawValue: kAXValueCGPointType)!, &val)!.takeRetainedValue()
    case var val as CGRect:
      return AXValueCreate(AXValueType(rawValue: kAXValueCGRectType)!, &val)!.takeRetainedValue()
    case var val as CGSize:
      return AXValueCreate(AXValueType(rawValue: kAXValueCGSizeType)!, &val)!.takeRetainedValue()
    default:
      return value as! AnyObject  // must be an object to pass to AX
    }
  }

  /// Gets multiple attributes of the element at once.
  ///
  /// - parameter attributes: An array of attribute names. Nonexistent attributes are ignored.
  ///
  /// - returns: A dictionary mapping provided parameter names to their values. Parameters which
  ///            don't exist or have no value will be absent.
  ///
  /// - throws: If there are any errors other than .NoValue or .AttributeUnsupported, it will throw
  ///           the first one it encounters.
  ///
  /// - note: Presumably you would use this API for performance, though it's not explicitly
  ///         documented by Apple that there is actually a difference.
  public func getMultipleAttributes(names: Attribute...) throws -> [Attribute: Any] {
    return try getMultipleAttributes(names)
  }

  public func getMultipleAttributes(attributes: [Attribute]) throws -> [Attribute: Any] {
    let values = try fetchMultiAttrValues(attributes.map({ $0.rawValue }))
    return try packMultiAttrValues(attributes, values: values)
  }

  public func getMultipleAttributes(attributes: [String]) throws -> [String: Any] {
    let values = try fetchMultiAttrValues(attributes)
    return try packMultiAttrValues(attributes, values: values)
  }

  // Helper: Gets list of values
  private func fetchMultiAttrValues(attributes: [String]) throws -> [AnyObject] {
    var valuesCF: CFArray?
    let error = AXUIElementCopyMultipleAttributeValues(
      element,
      attributes,
      AXCopyMultipleAttributeOptions(rawValue: 0),  // keep going on errors (particularly NoValue)
      &valuesCF)

    guard error == .Success else {
      throw error
    }

    return valuesCF! as [AnyObject]
  }

  // Helper: Packs names, values into dictionary
  private func packMultiAttrValues<Attr>(attributes: [Attr], values: [AnyObject]) throws -> [Attr: Any] {
    var result = [Attr: Any]()
    for (index, attribute) in attributes.enumerate() {
      if try checkMultiAttrValue(values[index]) {
        result[attribute] = unpackAXValue(values[index])
      }
    }
    return result
  }

  // Helper: Checks if value is present and not an error (throws on nontrivial errors).
  private func checkMultiAttrValue(value: AnyObject) throws -> Bool {
    // Check for null
    if value is NSNull {
      return false
    }

    // Check for error
    if CFGetTypeID(value) == AXValueGetTypeID() &&
       AXValueGetType(value as! AXValue).rawValue == kAXValueAXErrorType {
      var error: AXError = AXError.Success;
      AXValueGetValue(value as! AXValue, AXValueType(rawValue: kAXValueAXErrorType)!, &error)

      assert(error != .Success)
      if error == .NoValue || error == .AttributeUnsupported {
        return false
      } else {
        throw error
      }
    }

    return true
  }

  // MARK: Array attributes

  /// Returns a subset of values from an array attribute.
  ///
  /// - parameter attribute: The name of the array attribute.
  /// - parameter startAtIndex: The index of the array to start taking values from.
  /// - parameter maxValues: The maximum number of values you want.
  ///
  /// - returns: An array of up to `maxValues` values starting at `startAtIndex`.
  ///   - The array is empty if `startAtIndex` is out of range.
  ///   - `nil` if the attribute doesn't exist or has no value.
  ///
  /// - throws: `Error.IllegalArgument` if the attribute isn't an array.
  public func valuesForAttribute<T: AnyObject>
      (attribute: Attribute, startAtIndex index: Int, maxValues: Int) throws -> [T]? {
    return try valuesForAttribute(attribute.rawValue, startAtIndex: index, maxValues: maxValues)
  }

  public func valuesForAttribute<T: AnyObject>
      (attribute: String, startAtIndex index: Int, maxValues: Int) throws -> [T]? {
    var values: CFArray?
    let error = AXUIElementCopyAttributeValues(element, attribute, index, maxValues, &values)

    if error == .NoValue || error == .AttributeUnsupported {
      return nil
    }

    guard error == .Success else {
      throw error
    }

    return (values! as [AnyObject] as! [T])
  }

  /// Returns the number of values an array attribute has.
  /// - returns: The number of values, or `nil` if `attribute` isn't an array (or doesn't exist).
  public func valueCountForAttribute(attribute: Attribute) throws -> Int? {
    return try valueCountForAttribute(attribute.rawValue)
  }

  public func valueCountForAttribute(attribute: String) throws -> Int? {
    var count: Int = 0
    let error = AXUIElementGetAttributeValueCount(element, attribute, &count)

    if error == .AttributeUnsupported || error == .IllegalArgument {
      return nil
    }

    guard error == .Success else {
      throw error
    }

    return count
  }

  // MARK: Parameterized attributes

  /// Returns a list of all parameterized attributes of the element.
  ///
  /// Parameterized attributes are attributes that require parameters to retrieve. For example,
  /// the cell contents of a spreadsheet might require the row and column of the cell you want.
  public func parameterizedAttributes() throws -> [Attribute] {
    return try parameterizedAttributesAsStrings().flatMap({ Attribute(rawValue: $0) })
  }

  public func parameterizedAttributesAsStrings() throws -> [String] {
    var names: CFArray?
    let error = AXUIElementCopyParameterizedAttributeNames(element, &names)

    if error == .NoValue || error == .AttributeUnsupported {
      return []
    }

    guard error == .Success else {
      throw error
    }

    // We must first convert the CFArray to a native array, then downcast to an array of strings.
    return names! as [AnyObject] as! [String]
  }

  /// Returns the value of the parameterized attribute `attribute` with parameter `param`.
  ///
  /// The expected type of `param` depends on the attribute. See the
  /// [NSAccessibility Informal Protocol Reference](https://developer.apple.com/library/mac/documentation/Cocoa/Reference/ApplicationKit/Protocols/NSAccessibility_Protocol/)
  /// for more info.
  public func parameterizedAttribute<T, U>(attribute: Attribute, param: U) throws -> T? {
    return try parameterizedAttribute(attribute.rawValue, param: param)
  }

  public func parameterizedAttribute<T, U>(attribute: String, param: U) throws -> T? {
    var value: AnyObject?
    let error = AXUIElementCopyParameterizedAttributeValue(element, attribute, param as! AnyObject, &value)

    if error == .NoValue || error == .AttributeUnsupported {
      return nil
    }

    guard error == .Success else {
      throw error
    }

    return (value as! T)
  }

  // MARK: - Actions

  /// Returns a list of actions that can be performed on the element.
  public func actions() throws -> [Action] {
    return try actionsAsStrings().flatMap({ Action(rawValue: $0) })
  }

  public func actionsAsStrings() throws -> [String] {
    var names: CFArray?
    let error = AXUIElementCopyActionNames(element, &names)

    if error == .NoValue || error == .AttributeUnsupported {
      return []
    }

    guard error == .Success else {
      throw error
    }

    // We must first convert the CFArray to a native array, then downcast to an array of strings.
    return names! as [AnyObject] as! [String]
  }

  /// Returns the human-readable description of `action`.
  public func actionDescription(action: Action) throws -> String? {
    return try actionDescription(action.rawValue)
  }

  public func actionDescription(action: String) throws -> String? {
    var description: CFString?
    let error = AXUIElementCopyActionDescription(element, action, &description)

    if error == .NoValue || error == .ActionUnsupported {
      return nil
    }

    guard error == .Success else {
      throw error
    }

    return description! as String
  }

  /// Performs the action `action` on the element, returning on success.
  ///
  /// - note: If the action times out, it might mean that the application is taking a long time to
  ///         actually perform the action. It doesn't necessarily mean that the action wasn't performed.
  /// - throws: `Error.ActionUnsupported` if the action is not supported.
  public func performAction(action: Action) throws {
    try performAction(action.rawValue)
  }

  public func performAction(action: String) throws {
    let error = AXUIElementPerformAction(element, action)

    guard error == .Success else {
      throw error
    }
  }

  // MARK: -

  /// Returns the process ID of the application that the element is a part of.
  ///
  /// Throws only if the element is invalid (`Errors.InvalidUIElement`).
  public func pid() throws -> pid_t {
    var pid: pid_t = -1
    let error = AXUIElementGetPid(element, &pid)

    guard error == .Success else {
      throw error
    }

    return pid
  }

  /// The timeout in seconds for all messages sent to this element. Use this to control how long
  /// a method call can delay execution. The default is `0`, which means to use the global timeout.
  ///
  /// - note: Only applies to this instance of UIElement, not other instances that happen to equal it.
  /// - seeAlso: `UIElement.globalMessagingTimeout(_:)`
  public var messagingTimeout: Float = 0 {
    didSet {
      messagingTimeout = max(messagingTimeout, 0)
      let error = AXUIElementSetMessagingTimeout(element, messagingTimeout)

      // InvalidUIElement errors are only relevant when actually passing messages, so we can ignore
      // them here.
      guard error == .Success || error == .InvalidUIElement else {
        fatalError("Unexpected error setting messaging timeout: \(error)")
      }
    }
  }

  // Gets the element at the specified coordinates.
  // This can only be called on applications and the system-wide element, so it is internal here.
  func elementAtPosition(x: Float, _ y: Float) throws -> UIElement? {
    var result: AXUIElement?
    let error = AXUIElementCopyElementAtPosition(element, x, y, &result)

    if error == .NoValue {
      return nil
    }

    guard error == .Success else {
      throw error
    }

    return UIElement(result!)
  }

  // TODO: convenience functions for attributes
  // TODO: get any attribute as a UIElement or [UIElement] (or a subclass)
  // TODO: promoters
}

// MARK: - CustomStringConvertible

extension UIElement: CustomStringConvertible {
  public var description: String {
    var role: String
    do {
      try role = self.role()?.rawValue ?? "UIElementNoRole"
    } catch AXError.InvalidUIElement {
      role = "InvalidUIElement"
    } catch {
      role = "UnknownUIElement"
    }
    return "\(role): \(element)"
  }
}

// MARK: - Equatable

extension UIElement: Equatable { }
public func ==(lhs: UIElement, rhs: UIElement) -> Bool {
  return CFEqual(lhs.element, rhs.element)
}

// MARK: - Convenience getters

extension UIElement {
  /// Returns the role (type) of the element, if it reports one.
  ///
  /// Almost all elements report a role, but this could return nil for elements that aren't finished
  /// initializing.
  ///
  /// - seeAlso: [Roles](https://developer.apple.com/library/mac/documentation/AppKit/Reference/NSAccessibility_Protocol_Reference/index.html#//apple_ref/doc/constant_group/Roles)
  public func role() throws -> Role? {
    // should this be non-optional?
    if let str: String = try self.attribute(.Role) {
      return Role(rawValue: str)
    } else {
      return nil
    }
  }

  /// - seeAlso: [Subroles](https://developer.apple.com/library/mac/documentation/AppKit/Reference/NSAccessibility_Protocol_Reference/index.html#//apple_ref/doc/constant_group/Subroles)
  public func subrole() throws -> Subrole? {
    if let str: String = try self.attribute(.Subrole) {
      return Subrole(rawValue: str)
    } else {
      return nil
    }
  }
}