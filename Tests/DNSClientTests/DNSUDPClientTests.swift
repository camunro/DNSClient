import XCTest
import NIO
import DNSClient

#if canImport(Network)
import NIOTransportServices
#endif

final class DNSUDPClientTests: XCTestCase {
    var group: MultiThreadedEventLoopGroup!
    var dnsClient: DNSClient!

    #if canImport(Network)
    var nwGroup: NIOTSEventLoopGroup!
    var nwDnsClient: DNSClient!
    #endif

    @available(*, noasync)
    func testClient(_ perform: (DNSClient) throws -> Void) rethrows -> Void {
        try perform(dnsClient)
        #if canImport(Network)
        try perform(nwDnsClient)
        #endif
    }

    func testClient(_ perform: (DNSClient) async throws -> Void) async rethrows -> Void {
        try await perform(dnsClient)
        #if canImport(Network)
        try await perform(nwDnsClient)
        #endif
    }

    override func setUpWithError() throws {
        group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        dnsClient = try DNSClient.connect(on: group, host: "8.8.8.8").wait()
        #if canImport(Network)
        nwGroup = NIOTSEventLoopGroup(loopCount: 1)
        nwDnsClient = try DNSClient.connectTS(on: nwGroup, host: "8.8.8.8").wait()
        #endif
    }
    
    func testStringAddress() throws {
        var buffer = ByteBuffer()
        buffer.writeInteger(0x7F000001 as UInt32)
        guard let record = ARecord.read(from: &buffer, length: buffer.readableBytes) else {
            XCTFail()
            return
        }
        
        XCTAssertEqual(record.stringAddress, "127.0.0.1")
    }

    func testStringAddressAAAA() throws {
        var buffer = ByteBuffer()
        buffer.writeBytes([0x2a, 0x00, 0x14, 0x50, 0x40, 0x01, 0x08, 0x09, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x20, 0x0e] as [UInt8])

        guard let record = AAAARecord.read(from: &buffer, length: buffer.readableBytes) else {
            XCTFail()
            return
        }

        XCTAssertEqual(record.stringAddress, "2a00:1450:4001:0809:0000:0000:0000:200e")
    }

    func testAQuery() throws {
        try testClient { dnsClient in
            let results = try dnsClient.initiateAQuery(host: "google.com", port: 443).wait()
            XCTAssertGreaterThanOrEqual(results.count, 1, "The returned result should be greater than or equal to 1")
        }
    }

    func testAAAAQuery() throws {
        try testClient { dnsClient in
            let results = try dnsClient.initiateAAAAQuery(host: "google.com", port: 443).wait()
            XCTAssertGreaterThanOrEqual(results.count, 1, "The returned result should be greater than or equal to 1")
        }
    }

    func testSendTxtQuery() throws {
        try testClient { dnsClient in
            let result = try dnsClient.sendQuery(forHost: "google.com", type: .txt).wait()
            XCTAssertEqual(result.header.answerCount, 0, "The returned answers should be 0 on UDP")
        }
    }

    func testSendQueryMX() throws {
        try testClient { dnsClient in
            let result = try dnsClient.sendQuery(forHost: "gmail.com", type: .mx).wait()
            XCTAssertGreaterThanOrEqual(result.header.answerCount, 1, "The returned answers should be greater than or equal to 1")
        }
    }

    func testSendQueryCNAME() throws {
        try testClient { dnsClient in
            let result = try dnsClient.sendQuery(forHost: "www.youtube.com", type: .cName).wait()
            XCTAssertGreaterThanOrEqual(result.header.answerCount, 1, "The returned answers should be greater than or equal to 1")
        }
    }

    func testSRVRecords() throws {
        try testClient { dnsClient in
            let answers = try dnsClient.getSRVRecords(from: "_caldavs._tcp.google.com").wait()
            XCTAssertGreaterThanOrEqual(answers.count, 1, "The returned answers should be greater than or equal to 1")
        }
    }

    func testNSQuery() throws {
        try testClient { dnsClient in
            let results = try dnsClient.initiateNSQuery(forDomain: "example.com").wait()
            XCTAssertEqual(results.count, 2)
            let names = results.map { $0.resource.labels.string }.sorted()
            XCTAssertEqual(names, ["a.iana-servers.net", "b.iana-servers.net"])
        }
    }

    func testSOAQuery() throws {
        try testClient { dnsClient in
            let results = try dnsClient.initiateSOAQuery(forDomain: "example.com").wait()
            XCTAssertEqual(results.count, 1)
            XCTAssertEqual(results.first?.resource.mname.string, "ns.icann.org")
        }
    }
    
    func testSRVRecordsAsyncRequest() throws {
        testClient { dnsClient in
            let expectation = self.expectation(description: "getSRVRecords")
            
            dnsClient.getSRVRecords(from: "_caldavs._tcp.google.com")
                .whenComplete { (result) in
                    switch result {
                    case .failure(let error):
                        XCTFail("\(error)")
                    case .success(let answers):
                        XCTAssertGreaterThanOrEqual(answers.count, 1, "The returned answers should be greater than or equal to 1")
                    }
                    expectation.fulfill()
                }
            self.waitForExpectations(timeout: 5, handler: nil)
        }
    }
    
    // func testSRVRecordsAsyncRequest2() async throws {
    //     try await testClient { dnsClient in
    //         for _ in 0..<50 {
    //             let answers = try await dnsClient.getSRVRecords(from: "_caldavs._tcp.google.com").get()
    //             XCTAssertGreaterThanOrEqual(answers.count, 1, "The returned answers should be greater than or equal to 1")
    //             for answer in answers {
    //                 let countA = try await dnsClient.initiateAAAAQuery(host: answer.resource.domainName.string, port: 27017).get().count
    //                 let countAAAA = try await dnsClient.initiateAQuery(host: answer.resource.domainName.string, port: 27017).get().count
                    
    //                 XCTAssertGreaterThan(countA + countAAAA, 0)
    //             }
    //         }
    //     }
    // }
    
    // 4.4.8.8.in-addr.arpa domain points to dns.google.
    func testipv4InverseAddress() throws {
        let answers = try dnsClient.ipv4InverseAddress("8.8.4.4").wait()
        // print("getIPv4PTRRecords: ", answers[0].resource.domainName.string)
        
        XCTAssertGreaterThanOrEqual(answers.count, 1, "The returned answers should be greater than or equal to 1")
    }
    
    //  'nslookup 208.67.222.222' has multiple (3) PTR records for opendns.com
    func testipv4InverseAddressMultipleResponses() throws {
        let answers = try dnsClient.ipv4InverseAddress("208.67.222.222").wait()
        
        // for answer in answers {
        //  print("testPTRRecords2", answer.domainName.string)
        //  print("testPTRRecords2", answer.resource.domainName.string)
        // }
        
        XCTAssertGreaterThanOrEqual(answers.count, 1, "The returned answers should be greater than or equal to 1")
    }
    
    func testipv6InverseAddress() throws {
        // dns.google.
        // let answers = try dnsClient.ipv6InverseAddress("2001:4860:4860::8844").wait()
        
        // j.root-servers.net operated by Verisign, Inc.
        let answers = try dnsClient.ipv6InverseAddress("2001:503:c27::2:30").wait()
        // print("getIPv6PTRRecords: ", answers[0].resource.domainName.string)
        
        XCTAssertGreaterThanOrEqual(answers.count, 1, "The returned answers should be greater than or equal to 1")
    }
    
    func testipv6InverseAddressInvalidInput() throws {
        XCTAssertThrowsError(try dnsClient.ipv6InverseAddress(":::0").wait()) { error in
            
            #if os(Linux)
            XCTAssertEqual(error.localizedDescription , "The operation could not be completed. (NIOCore.IOError error 1.)")
            #else
            XCTAssertEqual(error.localizedDescription , "The operation couldn’t be completed. (NIOCore.IOError error 1.)")
            #endif
        }
    }
    
    func testPTRRecordDescription() throws {
        let domainname = PTRRecord(domainName: [DNSLabel(stringLiteral: "dns"),
                                               DNSLabel(stringLiteral: "google"),
                                               DNSLabel(stringLiteral: "")])
        
        XCTAssertEqual(domainname.description, "PTRRecord: dns.google")
    }
    
    func testClientReuseBehavior() {
        //
        // MARK: - Test 1: Standard NIO Client (dnsClient) - Should SUCCEED
        //
        print("\n--- Starting Test: Standard NIO Client (Should Succeed) ---")
        let standardClientExpectation = self.expectation(description: "The second query on the standard NIO client should succeed")
        
        let firstQueryFuture = self.dnsClient.ipv4InverseAddress("8.8.8.8")
        let secondQueryFuture = firstQueryFuture.flatMap { ptrRecords -> EventLoopFuture<[SocketAddress]> in
            XCTAssertFalse(ptrRecords.isEmpty, "Standard NIO client: First query should succeed")
            print("Test: Standard NIO client's first query succeeded. Starting second query...")
            return self.dnsClient.initiateAQuery(host: "dns.google", port: 443)
        }

        secondQueryFuture.whenComplete { result in
            switch result {
            case .success(let aRecords):
                XCTAssertFalse(aRecords.isEmpty, "Standard NIO client: Second query should also succeed")
                print("Test: Standard NIO client's second query succeeded as expected.")
                standardClientExpectation.fulfill()
            case .failure(let error):
                XCTFail("The standard NIO client's second query failed unexpectedly. Error: \(error)")
            }
            print("--- Finished Test: Standard NIO Client ---\n")
        }

        
        #if canImport(Network)
        //
        // MARK: - Test 2: Transport Services Client (nwDnsClient) - Should FAIL
        //
        print("--- Starting Test: Transport Services Client (Should Fail) ---")
        let transportServicesClientExpectation = self.expectation(description: "The second query on the Transport Services client should fail")

        let firstTSQueryFuture = self.nwDnsClient.ipv4InverseAddress("8.8.8.8")
        let secondTSQueryFuture = firstTSQueryFuture.flatMap { ptrRecords -> EventLoopFuture<[SocketAddress]> in
            XCTAssertFalse(ptrRecords.isEmpty, "Transport Services client: First query should succeed")
            print("Test: Transport Services client's first query succeeded. Starting second query...")
            return self.nwDnsClient.initiateAQuery(host: "dns.google", port: 443)
        }

        secondTSQueryFuture.whenComplete { result in
            switch result {
                case .success(_): // let aRecords
                XCTFail("The Transport Services client's second query succeeded, but it was expected to fail. The bug may be fixed.")
            case .failure(let error):
                print("Test: Transport Services client's second query failed as expected. Error: \(error)")
                transportServicesClientExpectation.fulfill()
            }
            print("--- Finished Test: Transport Services Client ---\n")
        }
        #endif

        
        // Wait for all expectations to be fulfilled.
        waitForExpectations(timeout: 35)
    }

    func testTSClientReuseScenarios() {
        #if canImport(Network)
        //
        // MARK: - V2 Test 1: Generic A -> A Query (Should Fail)
        //
        print("\n--- Starting Test V2: A -> A on Transport Services Client (Should Fail) ---")
        let expectation1 = self.expectation(description: "Second generic A query on TS client should fail")

        let client = self.nwDnsClient!
        let firstQuery = client.initiateAQuery(host: "iana.org", port: 443)
        let secondQuery = firstQuery.flatMap { firstResult -> EventLoopFuture<[SocketAddress]> in
            XCTAssertFalse(firstResult.isEmpty, "V2 Test 1: First A query should succeed.")
            print("Test V2: First A query succeeded.")
            return client.initiateAQuery(host: "icann.org", port: 443)
        }

        secondQuery.whenComplete { result in
            switch result {
            case .success:
                XCTFail("V2 Test 1: Second A query succeeded unexpectedly.")
            case .failure:
                print("Test V2: Second A query failed as expected.")
                expectation1.fulfill()
            }
            print("--- Finished Test V2: A -> A ---\n")
        }

        //
        // MARK: - V2 Test 2: Raw PTR -> A Query (Should Fail)
        //
        print("--- Starting Test V2: Raw PTR -> A on Transport Services Client (Should Fail) ---")
        let expectation2 = self.expectation(description: "Second query after raw PTR on TS client should fail")

        let firstRawQuery = client.sendQuery(forHost: "8.8.8.8.in-addr.arpa", type: .ptr)
        let secondAfterRawQuery = firstRawQuery.flatMap { firstResult -> EventLoopFuture<Message> in
            XCTAssertFalse(firstResult.answers.isEmpty, "V2 Test 2: Raw PTR query should succeed.")
            print("Test V2: Raw PTR query succeeded.")
            return client.sendQuery(forHost: "dns.google", type: .a)
        }

        secondAfterRawQuery.whenComplete { result in
            switch result {
            case .success:
                XCTFail("V2 Test 2: Second query after raw PTR succeeded unexpectedly.")
            case .failure:
                print("Test V2: Second query after raw PTR failed as expected.")
                expectation2.fulfill()
            }
            print("--- Finished Test V2: Raw PTR -> A ---\n")
        }
        #endif

        waitForExpectations(timeout: 35)
    }
}
