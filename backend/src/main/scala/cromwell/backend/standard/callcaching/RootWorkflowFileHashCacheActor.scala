package cromwell.backend.standard.callcaching

import java.util.concurrent.TimeoutException

import akka.actor.{Actor, ActorLogging, ActorRef}
import cats.data.NonEmptyList
import cats.data.Validated.{Invalid, Valid}
import cats.syntax.validated._
import com.google.common.cache.{CacheBuilder, CacheLoader, LoadingCache}
import common.validation.ErrorOr.ErrorOr
import cromwell.backend.standard.callcaching.RootWorkflowFileHashCacheActor.IoHashCommandWithContext
import cromwell.core.callcaching.{HashingFailedMessage, HashingServiceUnvailable}
import cromwell.core.io._


class RootWorkflowFileHashCacheActor(override val ioActor: ActorRef) extends Actor with ActorLogging with IoClientHelper {
  case class FileHashRequester(replyTo: ActorRef, fileHashContext: FileHashContext, ioCommand: IoCommand[_])

  sealed trait FileHashValue
  // The hash value is not yet in the cache and has not been requested.
  case object FileHashValueNotRequested extends FileHashValue
  // The hash value has been requested but is not yet in the cache.
  case class FileHashValueRequested(requesters: NonEmptyList[FileHashRequester]) extends FileHashValue
  // The hash value is in the cache.
  case class FileHashValuePresent(value: ErrorOr[String]) extends FileHashValue

  protected def ioCommandBuilder: IoCommandBuilder = DefaultIoCommandBuilder

  val cache: LoadingCache[String, FileHashValue] = CacheBuilder.newBuilder().build(
    new CacheLoader[String, FileHashValue] {
      override def load(key: String): FileHashValue = FileHashValueNotRequested
    })

  override protected def onTimeout(message: Any, to: ActorRef): Unit = {
    message match {
      case (_, ioHashCommand: IoHashCommand) =>
        val fileAsString = ioHashCommand.file.pathAsString
        context.parent !
          HashingFailedMessage(fileAsString, new TimeoutException(s"Hashing request timed out for: $fileAsString"))
      case other =>
        // This should never happen... but at least send _something_ before this actor goes silent.
        log.warning(s"Root workflow file hash caching actor received unexpected timeout message: $other")
        context.parent ! HashingServiceUnvailable
    }
  }

  override def receive: Receive = ioReceive orElse cacheOrHashReceive

  val cacheOrHashReceive: Receive = {
    // Hash Request
    case hashCommand: IoHashCommandWithContext =>
      val key = hashCommand.fileHashContext.file
      lazy val requester = FileHashRequester(sender, hashCommand.fileHashContext, hashCommand.ioHashCommand)
      cache.get(key) match {
        case FileHashValueNotRequested =>
          // The hash is not in the cache and has not been requested. Make the hash request and register this requester
          // to be notified when the hash value becomes available.
          // System.err.println(s"I DO DECLARE THAT A FILE HASH IS NEEDED RIGHT ABOUT NOW FOR $key")
          sendIoCommandWithContext(hashCommand.ioHashCommand, hashCommand.fileHashContext)
          cache.put(key, FileHashValueRequested(requesters = NonEmptyList.of(requester)))
        case FileHashValueRequested(requesters) =>
          // We don't have the hash but it has already been requested. Just add this requester and continue waiting for the
          // hash to become available.
          cache.put(key, FileHashValueRequested(requesters = requester :: requesters))
        case FileHashValuePresent(value) =>
          val ioResponse: IoAck[_] = value match {
            case Valid(v: String) => IoSuccess(requester.ioCommand, v)
            case Invalid(e) => IoFailure(requester.ioCommand, new RuntimeException(s"Error hashing file '$key': ${e.toList.mkString(", ")}"))
          }
          sender ! Tuple2(hashCommand.fileHashContext, ioResponse)
      }
    // Hash Success
    case (hashContext: FileHashContext, success @ IoSuccess(_, value: String)) =>
      handleHashResult(success, hashContext) { requesters =>
        requesters.toList foreach { case FileHashRequester(replyTo, fileHashContext, ioCommand) =>
          replyTo ! Tuple2(fileHashContext, IoSuccess(ioCommand, success.result))
        }
        cache.put(hashContext.file, FileHashValuePresent(value.validNel))
      }
    // Hash Failure
    case (hashContext: FileHashContext, failure: IoFailure[_]) =>
      handleHashResult(failure, hashContext) { requesters =>
        // All requesters can get the same response in the case of failure.
        val response = HashingFailedMessage(hashContext.file, failure.failure)
        requesters.toList foreach { case FileHashRequester(replyTo, _, ioCommand) =>
          replyTo ! Tuple2(ioCommand, response)
        }
        cache.put(hashContext.file, FileHashValuePresent(s"Error hashing file: ${failure.failure.getMessage}".invalidNel))
      }
    case other =>
      log.warning(s"Root workflow file hash caching actor received unexpected message: $other")
  }

  // Invoke the supplied block on the happy path, handle unexpected states for IoSuccess and IoFailure with common code.
  private def handleHashResult(ioAck: IoAck[_], fileHashContext: FileHashContext)
                              (notifyRequestersAndCacheValue: NonEmptyList[FileHashRequester] => Unit): Unit = {
    cache.get(fileHashContext.file) match {
      case FileHashValueRequested(requesters) => notifyRequestersAndCacheValue(requesters)
      case FileHashValueNotRequested =>
        log.error(s"Programmer error! Not expecting message type ${ioAck.getClass.getSimpleName} with no requesters for the hash: $fileHashContext")
      case FileHashValuePresent(_) =>
        log.error(s"Programmer error! Not expecting message type ${ioAck.getClass.getSimpleName} when the hash value has already been received: $fileHashContext")
    }
  }
}

object RootWorkflowFileHashCacheActor {
  case class IoHashCommandWithContext(ioHashCommand: IoHashCommand, fileHashContext: FileHashContext)
}
