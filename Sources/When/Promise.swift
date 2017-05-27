import Foundation

open class Promise<T> {
  public typealias DoneHandler = (T) -> Void
  public typealias FailureHandler = (Error) -> Void
  public typealias CompletionHandler = (Result<T>) -> Void

  public let key = UUID().uuidString
  fileprivate(set) var queue: DispatchQueue
  fileprivate(set) public var state: State<T>

  fileprivate(set) var observer: Observer<T>?
  fileprivate(set) var doneHandler: DoneHandler?
  fileprivate(set) var failureHandler: FailureHandler?
  fileprivate(set) var completionHandler: CompletionHandler?

  // MARK: - Initialization

  /// Create a promise that resolves using a synchronous closure
  public init(queue: DispatchQueue = mainQueue, _ body: @escaping (Void) throws -> T) {
    state = .pending
    self.queue = queue

    dispatch(queue) {
      do {
        let value = try body()
        self.resolve(value)
      } catch {
        self.reject(error)
      }
    }
  }

  /// Create a promise that resolves using an asynchronous closure that can either resolve or reject
  public init(queue: DispatchQueue = mainQueue,
              _ body: @escaping (_ resolve: (T) -> Void, _ reject: (Error) -> Void) -> Void) {
    state = .pending
    self.queue = queue
    
    dispatch(queue) {
      body(self.resolve, self.reject)
    }
  }

  /// Create a promise that resolves using an asynchronous closure that can only resolve
  public init(queue: DispatchQueue = mainQueue, _ body: @escaping (@escaping (T) -> Void) -> Void) {
    state = .pending
    self.queue = queue

    dispatch(queue) {
      body(self.resolve)
    }
  }

  /// Create a promise with a given state
  public init(queue: DispatchQueue = mainQueue, state: State<T> = .pending) {
    self.queue = queue
    self.state = state
  }

  // MARK: - States

  public func reject(_ error: Error) {
    guard self.state.isPending else {
      return
    }

    let state: State<T> = .rejected(error: error)
    update(state: state)
  }

  public func resolve(_ value: T) {
    guard self.state.isPending else {
      return
    }

    let state: State<T> = .resolved(value: value)
    update(state: state)
  }

  public func cancel() {
    reject(PromiseError.cancelled)
  }

  // MARK: - Callbacks

  @discardableResult public func done(_ handler: @escaping DoneHandler) -> Self {
    doneHandler = handler
    return self
  }

  @discardableResult public func fail(policy: FailurePolicy = .notCancelled,
                                    _ handler: @escaping FailureHandler) -> Self {
    failureHandler = { error in
      if case PromiseError.cancelled = error, policy == .notCancelled {
        return
      }
      handler(error)
    }
    return self
  }

  @discardableResult public func always(_ handler: @escaping CompletionHandler) -> Self {
    completionHandler = handler
    return self
  }

  // MARK: - Helpers

  private func update(state: State<T>?) {
    dispatch(queue) {
      guard let state = state, let result = state.result else {
        return
      }

      self.state = state
      self.notify(result)
    }
  }

  private func notify(_ result: Result<T>) {
    switch result {
    case let .success(value):
      doneHandler?(value)
    case let .failure(error):
      failureHandler?(error)
    }

    completionHandler?(result)

    if let observer = observer {
      dispatch(observer.queue) {
        observer.notify(result)
      }
    }

    doneHandler = nil
    failureHandler = nil
    completionHandler = nil
    observer = nil
  }

  fileprivate func addObserver<U>(on queue: DispatchQueue, promise: Promise<U>, _ body: @escaping (T) throws -> U?) {
    observer = Observer(queue: queue) { result in
      switch result {
      case let .success(value):
        do {
          if let result = try body(value) {
            promise.resolve(result)
          }
        } catch {
          promise.reject(error)
        }
      case let .failure(error):
        promise.reject(error)
      }
    }

    update(state: state)
  }

  private func dispatch(_ queue: DispatchQueue, closure: @escaping () -> Void) {
    if queue === instantQueue {
      closure()
    } else {
      queue.async(execute: closure)
    }
  }
}

// MARK: - Then

extension Promise {
  public func then<U>(on queue: DispatchQueue = mainQueue, _ body: @escaping (T) throws -> U) -> Promise<U> {
    let promise = Promise<U>(queue: queue)
    addObserver(on: queue, promise: promise, body)

    return promise
  }

  public func then<U>(on queue: DispatchQueue = mainQueue, _ body: @escaping (T) throws -> Promise<U>) -> Promise<U> {
    let promise = Promise<U>(queue: queue)

    addObserver(on: queue, promise: promise) { value -> U? in
      let nextPromise = try body(value)
      nextPromise.addObserver(on: queue, promise: promise) { value -> U? in
        return value
      }

      return nil
    }

    return promise
  }

  public func thenInBackground<U>(_ body: @escaping (T) throws -> U) -> Promise<U> {
    return then(on: backgroundQueue, body)
  }

  public func thenInBackground<U>(_ body: @escaping (T) throws -> Promise<U>) -> Promise<U> {
    return then(on: backgroundQueue, body)
  }

  func asVoid() -> Promise<Void> {
    return then(on: instantQueue) { _ in return }
  }
}
