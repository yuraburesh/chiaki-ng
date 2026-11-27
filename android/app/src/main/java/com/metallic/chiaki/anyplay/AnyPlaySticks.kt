// AnyPlay 138: чутливість стіків, як у налаштуваннях ігор. Невелике відхилення стіка дає повільний рух (іти),
// повне — біг. Три налаштування (меню гри → «Кнопки й вібрація», головна → «Вібрація»):
//  • чутливість — крива відгуку: плавно (точно на малих відхиленнях), звичайно, різко (як було до 138);
//  • мертва зона — скільки можна зрушити стік, перш ніж персонаж почне рух;
//  • хід екранного стіка — як далеко вести палець до повного відхилення.
// Те саме для екранних стіків (GamepadView) і геймпада через Bluetooth (StreamInput). iOS: Sticks у GamepadInput.swift.
package com.metallic.chiaki.anyplay

import android.content.Context
import org.json.JSONObject
import kotlin.math.hypot
import kotlin.math.pow

object AnyPlaySticks
{
	private const val PREFS = "anyplay_feel"
	private const val KEY_CURVE = "stickCurve"
	private const val KEY_DEAD = "stickDead"
	private const val KEY_TRAVEL = "stickTravel"

	private val EXP = floatArrayOf(2.2f, 1.6f, 1f)          // плавно, звичайно, різко
	private val DEAD = floatArrayOf(0.03f, 0.08f, 0.15f)    // мала, середня, велика
	private val TRAVEL = floatArrayOf(0.8f, 1f, 1.4f)       // короткий, середній, довгий

	@Volatile var curve = 1; private set
	@Volatile var dead = 1; private set
	@Volatile var travel = 1; private set

	fun load(c: Context)
	{
		val p = c.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
		curve = p.getInt(KEY_CURVE, 1).coerceIn(0, 2)
		dead = p.getInt(KEY_DEAD, 1).coerceIn(0, 2)
		travel = p.getInt(KEY_TRAVEL, 1).coerceIn(0, 2)
	}

	fun put(o: JSONObject): JSONObject = o.put(KEY_CURVE, curve).put(KEY_DEAD, dead).put(KEY_TRAVEL, travel)

	fun set(c: Context, o: JSONObject)
	{
		val e = c.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
		if(o.has(KEY_CURVE)) e.putInt(KEY_CURVE, o.optInt(KEY_CURVE, 1).coerceIn(0, 2))
		if(o.has(KEY_DEAD)) e.putInt(KEY_DEAD, o.optInt(KEY_DEAD, 1).coerceIn(0, 2))
		if(o.has(KEY_TRAVEL)) e.putInt(KEY_TRAVEL, o.optInt(KEY_TRAVEL, 1).coerceIn(0, 2))
		e.commit()
		load(c)
	}

	/** Множник ходу екранного стіка */
	fun travelK() = TRAVEL[travel]

	/** Відхилення стіка (-1..1 по осях) → що йде в гру: мертва зона й крива за довжиною, напрямок той самий */
	fun shape(x: Float, y: Float): Pair<Float, Float>
	{
		val len = hypot(x, y)
		val d = DEAD[dead]
		if(len <= d)
			return 0f to 0f
		val n = ((len - d) / (1f - d)).coerceIn(0f, 1f)
		val k = n.pow(EXP[curve]) / len
		return (x * k).coerceIn(-1f, 1f) to (y * k).coerceIn(-1f, 1f)
	}
}
