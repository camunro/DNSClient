import NIO
import NIOConcurrencyHelpers
import OSLog

final class EnvelopeInboundChannel: ChannelInboundHandler {
    typealias InboundIn = AddressedEnvelope<ByteBuffer>
    typealias InboundOut = ByteBuffer
    
    init() {}
    
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buffer = unwrapInboundIn(data).data
        context.fireChannelRead(wrapInboundOut(buffer))
    }
}

public final class DNSDecoder: ChannelInboundHandler, @unchecked Sendable {
    let group: EventLoopGroup
    let messageCache = NIOLockedValueBox<[UInt16: SentQuery]>([:])
    let clients = NIOLockedValueBox<[ObjectIdentifier: DNSClient]>([:])
    weak var mainClient: DNSClient?
    @available(macOS 11.0, iOS 14.0, *)
    private static let log = Logger(subsystem: "DNSClient", category: "DNSDecoder")

    public init(group: EventLoopGroup) {
        self.group = group
    }

    public typealias InboundIn = ByteBuffer
    public typealias OutboundOut = Never
    
    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buffer = unwrapInboundIn(data)
        if #available(macOS 11.0, iOS 14.0, *) {
            Self.log.debug("channelRead triggered with \(buffer.readableBytes) bytes.")
        }

        let message: Message
        do {
            message = try Self.parse(buffer)
        } catch {
            if #available(macOS 11.0, iOS 14.0, *) {
                Self.log.error("Error parsing message: \(error.localizedDescription)")
            }
            context.fireErrorCaught(error)
            return
        }

        if #available(macOS 11.0, iOS 14.0, *) {
            Self.log.debug("Successfully parsed message with ID \(message.header.id)")
        }

        if !message.header.options.contains(.answer) {
            if #available(macOS 11.0, iOS 14.0, *) {
                Self.log.debug("Message ID \(message.header.id) is not an answer, ignoring.")
            }
            return
        }

        messageCache.withLockedValue { cache in
            guard let query = cache[message.header.id] else {
                if #available(macOS 11.0, iOS 14.0, *) {
                    Self.log.warning("No promise found in cache for message ID \(message.header.id)")
                }
                return
            }

            if #available(macOS 11.0, iOS 14.0, *) {
                Self.log.debug("Promise found for ID \(message.header.id), succeeding promise.")
            }
            query.promise.succeed(message)
            cache[message.header.id] = nil
        }
    }

    public static func parse(_ buffer: ByteBuffer) throws -> Message {
        var buffer = buffer

        guard let header = buffer.readHeader() else {
            throw ProtocolError()
        }

        var questions = [QuestionSection]()

        for _ in 0..<header.questionCount {
            guard let question = buffer.readQuestion() else {
                throw ProtocolError()
            }

            questions.append(question)
        }

        func resourceRecords(count: UInt16) throws -> [Record] {
            var records = [Record]()

            for _ in 0..<count {
                guard let record = buffer.readRecord() else {
                    throw ProtocolError()
                }

                records.append(record)
            }

            return records
        }

        let answers = try resourceRecords(count: header.answerCount)
        let authorities = try resourceRecords(count: header.authorityCount)
        let additionalData = try resourceRecords(count: header.additionalRecordCount)

        return Message(
            header: header,
            questions: questions,
            answers: answers,
            authorities: authorities,
            additionalData: additionalData
        )
    }

    public func errorCaught(context ctx: ChannelHandlerContext, error: Error) {
        if #available(macOS 11.0, iOS 14.0, *) {
            Self.log.error("errorCaught triggered: \(error.localizedDescription)")
        }
        messageCache.withLockedValue { cache in
            for query in cache.values {
                query.promise.fail(error)
            }

            cache = [:]
        }
    }
}
