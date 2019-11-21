import XCTest
import class Foundation.Bundle
import JobsRedisDriver
import RedisKit
import NIO
@testable import Jobs
import Logging

let isLoggingConfigured: Bool = {
    LoggingSystem.bootstrap { label in
        var handler = StreamLogHandler.standardOutput(label: label)
        handler.logLevel = .debug
        return handler
    }
    return true
}()

final class JobsRedisDriverTests: XCTestCase {
    func testSettingValue() throws {
        let job = Email(to: "email@email.com")
        let jobData = try JSONEncoder().encode(job)
        let jobStorage = JobStorage(key: "key",
                                    data: jobData,
                                    maxRetryCount: 1,
                                    id: UUID().uuidString,
                                    jobName: EmailJob.jobName,
                                    delayUntil: nil,
                                    queuedAt: Date())
        
        try jobsDriver.set(key: "key", job: jobStorage, eventLoop: .indifferent).wait()
        
        XCTAssertNotNil(try redisConn.get(jobStorage.id).wait())
        
        guard let jobId = try redisConn.rpop(from: "key").wait().string else {
            XCTFail()
            return
        }
        
        guard let retrievedJobData = try redisConn.get(jobId).wait()?.data(using: .utf8) else {
            XCTFail()
            return
        }
        
        let decoder = try JSONDecoder().decode(DecoderUnwrapper.self, from: retrievedJobData)
        let retrievedJobStorage = try JobStorage(from: decoder.decoder)
        let retrievedJob = try JSONDecoder().decode(Email.self, from: retrievedJobStorage.data)
        
        XCTAssertEqual(retrievedJobStorage.maxRetryCount, 1)
        XCTAssertEqual(retrievedJobStorage.key, "key")
        XCTAssertEqual(retrievedJob.to, "email@email.com")
        
        //Assert that it was not added to the processing list
        XCTAssertEqual(try redisConn.lrange(within: (0, 0), from: "key-processing").wait().count, 0)
    }
    
    func testGettingValue() throws {
        let firstJob = Email(to: "email@email.com")
        let secondJob = Email(to: "email2@email.com")
        
        let firstJobData = try JSONEncoder().encode(firstJob)
        let secondJobData = try JSONEncoder().encode(secondJob)
        
        let firstJobStorage = JobStorage(key: "key",
                                         data: firstJobData,
                                         maxRetryCount: 1,
                                         id: UUID().uuidString,
                                         jobName: EmailJob.jobName,
                                         delayUntil: nil,
                                         queuedAt: Date())
        
        let secondJobStorage = JobStorage(key: "key",
                                          data: secondJobData,
                                          maxRetryCount: 1,
                                          id: UUID().uuidString,
                                          jobName: EmailJob.jobName,
                                          delayUntil: nil,
                                          queuedAt: Date())
        
        try jobsDriver.set(key: "key", job: firstJobStorage, eventLoop: .indifferent).wait()
        try jobsDriver.set(key: "key", job: secondJobStorage, eventLoop: .indifferent).wait()

        guard let fetchedJobData = try jobsDriver.get(key: "key", eventLoop: .indifferent).wait() else {
            XCTFail()
            return
        }

        let fetchedJob = try JSONDecoder().decode(Email.self, from: fetchedJobData.data)
        XCTAssertEqual(fetchedJob.to, "email@email.com")
        
        //Assert that the base list still has data in it and the processing list has 1
        XCTAssertNotEqual(try redisConn.lrange(within: (0, 0), from: "key").wait().count, 0)
        XCTAssertEqual(try redisConn.lrange(within: (0, 0), from: "key-processing").wait().count, 1)
        
        try jobsDriver.completed(key: "key", job: fetchedJobData, eventLoop: .indifferent).wait()
        XCTAssertEqual(try redisConn.lrange(within: (0, 0), from: "key-processing").wait().count, 0)
    }
    
    func testRequeue() throws {
        let job = Email(to: "email@email.com")
        let jobData = try JSONEncoder().encode(job)
        let jobStorage = JobStorage(key: "key",
                                    data: jobData,
                                    maxRetryCount: 1,
                                    id: UUID().uuidString,
                                    jobName: EmailJob.jobName,
                                    delayUntil: Date(timeIntervalSinceNow: 60),
                                    queuedAt: Date())
        
        try jobsDriver.set(key: "key", job: jobStorage, eventLoop: .indifferent).wait()
        
        XCTAssertNotNil(try redisConn.get(jobStorage.id).wait())
        XCTAssertNotNil(try jobsDriver.get(key: "key", eventLoop: .indifferent).wait())
        XCTAssertEqual(try redisConn.lrange(within: (0, 0), from: "key").wait().count, 0)
        XCTAssertEqual(try redisConn.lrange(within: (0, 0), from: "key-processing").wait().count, 1)
        
        try jobsDriver.requeue(key: "key", job: jobStorage, eventLoop: .indifferent).wait()
        
        XCTAssertNotNil(try redisConn.get(jobStorage.id).wait())
        XCTAssertEqual(try redisConn.lrange(within: (0, 0), from: "key").wait().count, 1)
        XCTAssertEqual(try redisConn.lrange(within: (0, 0), from: "key-processing").wait().count, 0)
    }

    func testJobsService() throws {
        let worker = JobsWorker(
            configuration: self.jobsConfig,
            driver: self.jobsDriver,
            logger: Logger(label: "com.vapor.test"),
            on: self.eventLoop
        )
        
        worker.start(on: .default)

        
        let jobs = TestingJobsService(
            configuration: self.jobsConfig,
            driver: self.jobsDriver,
            logger: Logger(label: "com.vapor.test"),
            eventLoopPreference: .indifferent
        )

        let dequeueCount = EmailJob.dequeueCount
        try jobs.dispatch(EmailJob.Data(to: "foo@vapor.codes")).wait()

        worker.shutdown()
        try worker.onShutdown.wait()

        XCTAssertEqual(EmailJob.dequeueCount, dequeueCount + 1)
    }

    // MARK: Setup

    var eventLoopGroup: EventLoopGroup!
    var eventLoop: EventLoop {
        self.eventLoopGroup.next()
    }
    var jobsDriver: JobsRedisDriver!
    var jobsConfig: JobsConfiguration!
    var redisConn: RedisClient {
        return self.connectionPool
    }
    var connectionPool: ConnectionPool<RedisConnectionSource>!

    override func setUp() {
        XCTAssert(isLoggingConfigured)

        self.eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        guard let url = URL(string: "redis://127.0.0.1:6379") else { return }
        guard let configuration = RedisConfiguration(url: url) else { return }

        let source = RedisConnectionSource(configuration: configuration)
        self.connectionPool = .init(.init(source: source, on: self.eventLoopGroup))
        self.jobsDriver = JobsRedisDriver(client: self.connectionPool, eventLoopGroup: self.eventLoopGroup)

        self.jobsConfig = JobsConfiguration()
        self.jobsConfig.add(EmailJob())
    }

    override func tearDown() {
        _ = try! redisConn.delete(["key"]).wait()
        _ = try! redisConn.delete(["key-processing"]).wait()
        self.connectionPool.shutdown()
        try! self.eventLoopGroup.syncShutdownGracefully()
    }
}

struct Email: Codable, JobData {
    let to: String
}

struct EmailJob: Job {
    static var dequeueCount = 0
    func dequeue(_ context: JobContext, _ data: Email) -> EventLoopFuture<Void> {
        EmailJob.dequeueCount += 1
        return context.eventLoop.makeSucceededFuture(())
    }
}

struct DecoderUnwrapper: Decodable {
    let decoder: Decoder
    init(from decoder: Decoder) { self.decoder = decoder }
}

struct TestingJobsService: JobsService {
    let configuration: JobsConfiguration
    let driver: JobsDriver
    let logger: Logger
    let eventLoopPreference: JobsEventLoopPreference
}
