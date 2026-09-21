package com.example.onedrama

import android.net.Uri
import android.util.Log
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.DataSpec
import androidx.media3.datasource.TransferListener
import java.nio.ByteBuffer
import java.nio.ByteOrder
import javax.crypto.Cipher
import javax.crypto.spec.IvParameterSpec
import javax.crypto.spec.SecretKeySpec

private const val TAG = "CencDecrypt"

/**
 * 流式解密数据源。
 *
 * 红果的流是**整样本 AES-128-CTR** 加密，而且连 NAL 长度前缀都是密的——media3 的提取器
 * 解析 NAL 时读到密文就抛 `Invalid NAL length`，所以在数据源这一层就得把字节解出来
 * （见 `docs/adr/0005`）。
 *
 * 做两件事：
 * 1. 按 [plan] 把 `moov` 里的加密盒子换成**等大** `free`、把 `encv`/`enca` 还原成
 *    `frma` 记录的原始格式——提取器于是把它当普通明文 MP4，一个偏移都不用重算。
 * 2. 按样本索引（偏移、长度、IV）就地 AES-CTR 解密。任意字节范围都能从正确的计数器
 *    位置起算，所以拖动进度条也没问题——这正是它比「先下载整集再解」强的地方。
 *
 * 解密计划由 Dart 侧算好传进来：协议知识留在 Dart，那边有 Go 包做对照（ADR-0003）。
 */
class CencDecryptDataSource(
    private val upstream: DataSource,
    private val key: ByteArray,
    private val plan: DecryptPlan,
) : DataSource {
    private var position = 0L

    override fun open(dataSpec: DataSpec): Long {
        position = dataSpec.position
        return upstream.open(dataSpec)
    }

    override fun read(buffer: ByteArray, offset: Int, length: Int): Int {
        val read = upstream.read(buffer, offset, length)
        if (read <= 0) return read

        applyPatches(position, buffer, offset, read)
        decryptRange(position, buffer, offset, read)

        position += read
        return read
    }

    override fun getUri(): Uri? = upstream.uri

    override fun close() = upstream.close()

    override fun addTransferListener(transferListener: TransferListener) =
        upstream.addTransferListener(transferListener)

    /** 抹掉加密痕迹。补丁都在 `moov` 里，条数是个位数，线性扫足够。 */
    private fun applyPatches(from: Long, buffer: ByteArray, offset: Int, length: Int) {
        val to = from + length
        for (patch in plan.patches) {
            val start = maxOf(from, patch.offset)
            val end = minOf(to, patch.offset + patch.bytes.size)
            if (start >= end) continue
            System.arraycopy(
                patch.bytes,
                (start - patch.offset).toInt(),
                buffer,
                offset + (start - from).toInt(),
                (end - start).toInt(),
            )
        }
    }

    /** 解密与这一段重叠的样本。 */
    private fun decryptRange(from: Long, buffer: ByteArray, offset: Int, length: Int) {
        val to = from + length
        var index = plan.firstSampleEndingAfter(from)
        while (index < plan.count) {
            val sampleStart = plan.offsets[index]
            if (sampleStart >= to) break

            val start = maxOf(from, sampleStart)
            val end = minOf(to, plan.offsets[index] + plan.sizes[index])
            if (start < end) {
                decryptSampleRange(
                    sample = index,
                    from = start,
                    target = buffer,
                    targetOffset = offset + (start - from).toInt(),
                    length = (end - start).toInt(),
                )
            }
            index++
        }
    }

    /**
     * 解一个样本里的一段。
     *
     * counter 块 = `IV ‖ 00000000_00000000`，低 8 字节按大端加上「块号」。这样从中间
     * 某一段起解也能对上——拖动进度条时就是这条路。
     */
    private fun decryptSampleRange(
        sample: Int,
        from: Long,
        target: ByteArray,
        targetOffset: Int,
        length: Int,
    ) {
        val offsetInSample = (from - plan.offsets[sample]).toInt()
        val blockIndex = offsetInSample / 16
        val skip = offsetInSample % 16

        val counter = ByteArray(16)
        System.arraycopy(plan.ivs, sample * 8, counter, 0, 8)
        var carry = blockIndex.toLong()
        var slot = 15
        while (slot >= 8 && carry != 0L) {
            val sum = (counter[slot].toInt() and 0xff) + (carry and 0xff).toInt()
            counter[slot] = sum.toByte()
            carry = (carry shr 8) + (sum shr 8)
            slot--
        }

        val cipher = Cipher.getInstance("AES/CTR/NoPadding")
        cipher.init(
            Cipher.DECRYPT_MODE,
            SecretKeySpec(key, "AES"),
            IvParameterSpec(counter),
        )
        // CTR 是流密码：先喂 skip 个零字节，把密钥流推到块内正确位置。
        if (skip > 0) cipher.update(ByteArray(skip))

        var produced = cipher.update(target, targetOffset, length, target, targetOffset)
        if (produced < length) {
            produced += cipher.doFinal(target, targetOffset + produced)
        }
    }
}

/**
 * 解密计划。由 Dart 侧的 `encodeDecryptPlan` 编码，小端。
 *
 * 布局：
 * ```
 * u32 版本 = 1
 * u32 样本数
 * u32 补丁数
 * 补丁 × N：u64 偏移, u32 长度, 字节
 * 样本 × N：u64 偏移, u32 长度, 8 字节 IV
 * ```
 */
class DecryptPlan(payload: ByteArray) {
    class Patch(val offset: Long, val bytes: ByteArray)

    val patches: List<Patch>
    val offsets: LongArray
    val sizes: IntArray

    /** 紧凑存的 IV：第 i 个样本的 8 字节在 `ivs[i*8 .. i*8+8)`。 */
    val ivs: ByteArray
    val count: Int

    init {
        val buffer = ByteBuffer.wrap(payload).order(ByteOrder.LITTLE_ENDIAN)
        val version = buffer.int
        require(version == 1) { "解密计划版本不认识：$version" }
        count = buffer.int
        val patchCount = buffer.int

        val patchList = ArrayList<Patch>(patchCount)
        repeat(patchCount) {
            val offset = buffer.long
            val size = buffer.int
            val bytes = ByteArray(size)
            buffer.get(bytes)
            patchList.add(Patch(offset, bytes))
        }
        patches = patchList

        offsets = LongArray(count)
        sizes = IntArray(count)
        ivs = ByteArray(count * 8)
        repeat(count) { index ->
            offsets[index] = buffer.long
            sizes[index] = buffer.int
            buffer.get(ivs, index * 8, 8)
        }
        Log.i(TAG, "解密计划：$count 个样本，${patchCount} 处补丁")
    }

    /** 第一个「结束位置大于 [from]」的样本下标。二分。 */
    fun firstSampleEndingAfter(from: Long): Int {
        var low = 0
        var high = count
        while (low < high) {
            val mid = (low + high) / 2
            if (offsets[mid] + sizes[mid] <= from) low = mid + 1 else high = mid
        }
        return low
    }
}
