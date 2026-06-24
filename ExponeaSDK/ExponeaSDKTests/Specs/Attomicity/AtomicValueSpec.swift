//
//  AtomicValueSpec.swift
//  ExponeaSDKTests
//
//  Created by Gustavo Pizano on 06/03/2023.
//  Copyright © 2023 Exponea. All rights reserved.
//

import Foundation
import XCTest
import Quick
import Nimble

@testable import ExponeaSDK

final class AtomicValueSpec: QuickSpec {

    private struct ComplexAtomicTestStruct {
        @Atomic var x = [1, 2, 3]
    }

    private struct SimpleAtomicTestStruct {
        @Atomic var x = 0
        @AtomicLock var y = true
        var atomicIntProperty = AtomicProperty(property: 0)
    }

    private let queue1 = DispatchQueue(label: "com.exponea.ExponeaSDK.atomicValueTestQueue1")
    private let queue2 = DispatchQueue(label: "com.exponea.ExponeaSDK.atomicValueTestQueue2")

    override func spec() {
        describe("Exponea Atomic Property wrapper") {
            context("Simple Atomic access operation") {
                var simpleTest = SimpleAtomicTestStruct()
                simpleTest.$x.changeValue { $0 += 1 }
                simpleTest.y = false
                it("Should be equals to 1") {
                    expect(simpleTest.x).to(equal(1))
                }
                it("Y Should be equals to false") {
                    expect(simpleTest.y).to(equal(false))
                }
            }

            context("Complex Atomic access operation") {
                var complexTest = ComplexAtomicTestStruct()
                complexTest.$x.changeValue { $0[0] += 1 }
                it("Should be equals to 2") {
                    expect(complexTest.x[1]).to(equal(2))
                }
            }

            // Multi-thread tests live inside a single `it` so the XCTest expectation
            // and `wait(for:timeout:)` calls happen at test-run time. Building the
            // expectations or calling `wait` at context-collection time (Quick's
            // `spec()` discovery pass) blocks the test-runner bootstrap and crashes
            // the suite before any test executes.
            context("Simple multi-thread reading/writting") {
                it("converges to the expected final values across two queues") {
                    var simpleTest = SimpleAtomicTestStruct()
                    let expectation = self.expectation(description: "Queues tasks completion")
                    expectation.expectedFulfillmentCount = 2

                    self.queue2.asyncAfter(deadline: .now() + 3) {
                        simpleTest.$x.changeValue { $0 += 1 }
                        simpleTest.y = true
                        simpleTest.atomicIntProperty.performAtomic { $0 += 1 }
                        expectation.fulfill()
                    }

                    self.queue1.asyncAfter(deadline: .now() + 1) {
                        simpleTest.$x.changeValue { $0 += 2 }
                        sleep(3)
                        simpleTest.y = false
                        simpleTest.atomicIntProperty.performAtomic { $0 = 4 }
                        expectation.fulfill()
                    }
                    self.wait(for: [expectation], timeout: 10)
                    expect(simpleTest.x).to(equal(3))
                    expect(simpleTest.y).to(equal(false))
                    expect(simpleTest.atomicIntProperty.property).to(equal(4))
                }
            }

            context("Complex multi-threading reading/writting") {
                it("serialises 20 parallel writers/readers without data race") {
                    var complexTest = SimpleAtomicTestStruct()
                    let writerExpectation = self.expectation(description: "Writers complete")
                    writerExpectation.expectedFulfillmentCount = 20
                    let readingExpectation = self.expectation(description: "Readers complete")
                    readingExpectation.expectedFulfillmentCount = 20
                    DispatchQueue.global().async {
                        for i in 1...20 {
                            let label = "com.exponea.ExponeaSDK.atomicValueComplexTestQueue" + String(i)
                            let queue = DispatchQueue(label: label)
                            let delay = Double(20 - i)
                            queue.asyncAfter(deadline: .now() + delay) {
                                complexTest.$x.changeValue { $0 += 1 }
                                writerExpectation.fulfill()
                                expect(complexTest.x).to(beGreaterThan(0))
                                expect(complexTest.x).to(beLessThanOrEqualTo(20))
                            }
                        }
                    }
                    DispatchQueue.global().async {
                        for i in 1...20 {
                            DispatchQueue.global().sync {
                                sleep(UInt32(i / 2))
                                expect(complexTest.x).to(beGreaterThanOrEqualTo(0))
                                expect(complexTest.x).to(beLessThanOrEqualTo(20))
                                readingExpectation.fulfill()
                            }
                        }
                    }
                    self.wait(for: [writerExpectation, readingExpectation], timeout: 200)
                    expect(complexTest.x).to(equal(20))
                }
            }

            context("AtomicProperty nil handling") {
                it("starts nil when using the no-arg initializer") {
                    let prop = AtomicProperty<Int>()
                    expect(prop.property).to(beNil())
                }

                it("skips performAtomic when property is nil") {
                    let prop = AtomicProperty<Int>()
                    var callbackInvoked = false
                    prop.performAtomic { _ in callbackInvoked = true }
                    expect(callbackInvoked).to(beFalse())
                    expect(prop.property).to(beNil())
                }

                it("executes performAtomic after property is set") {
                    let prop = AtomicProperty(property: 10)
                    prop.performAtomic { $0 += 5 }
                    expect(prop.property).to(equal(15))
                }

                it("can be set back to nil") {
                    let prop = AtomicProperty(property: 42)
                    expect(prop.property).to(equal(42))
                    prop.property = nil
                    expect(prop.property).to(beNil())
                }
            }

            context("Atomic under high contention") {
                it("increments correctly from 100 concurrent queues") {
                    let counter = Atomic(wrappedValue: 0)
                    let done = self.expectation(description: "All Atomic writers finish")
                    done.expectedFulfillmentCount = 100
                    for _ in 0..<100 {
                        DispatchQueue.global().async {
                            counter.changeValue { $0 += 1 }
                            done.fulfill()
                        }
                    }
                    self.wait(for: [done], timeout: 30)
                    expect(counter.wrappedValue).to(equal(100))
                }
            }
        }
    }
}
