WITH 
-- 1. Генерируем временную сетку для активных машин
time_grid AS (
    SELECT 
        m.machine_id,
        m.machine_name,
        m.commissioned_at,
        mt.type_name AS machine_type,
        generate_series(
            date_trunc('hour', '2025-01-10 07:00:00'::timestamp),
            date_trunc('hour', '2025-06-30 22:00:00'::timestamp),
            interval '1 hour'
        ) AS snapshot_time
    FROM machines m
    LEFT JOIN machine_types mt ON m.machine_type_id = mt.machine_type_id 
    WHERE m.status = 'ACTIVE'
),

-- 2. Пред-агрегируем показания сенсоров по часам
hourly_sensors AS (
    SELECT 
        s.machine_id,
        date_trunc('hour', sr.recorded_at) AS hr,
        AVG(CASE WHEN st.type_code = 'TEMPERATURE' THEN sr.numeric_value END) AS temp_hr,
        AVG(CASE WHEN st.type_code = 'VIBRATION' THEN sr.numeric_value END) AS vib_hr,
        AVG(CASE WHEN st.type_code = 'PRESSURE' THEN sr.numeric_value END) AS press_hr,
        AVG(CASE WHEN st.type_code = 'RPM' THEN sr.numeric_value END) AS rpm_hr,
        AVG(CASE WHEN st.type_code = 'POWER' THEN sr.numeric_value END) AS power_hr,
        AVG(CASE WHEN st.type_code = 'HUMIDITY' THEN sr.numeric_value END) AS humidity_hr
    FROM sensor_readings sr
    JOIN sensors s ON sr.sensor_id = s.sensor_id
    JOIN sensor_types st ON s.sensor_type_id = st.sensor_type_id
    GROUP BY s.machine_id, date_trunc('hour', sr.recorded_at)
),

-- 3. Пред-агрегируем события оборудования по часам
hourly_events AS (
    SELECT 
        me.machine_id,
        date_trunc('hour', me.started_at) AS hr,
        COUNT(CASE WHEN met.event_code = 'STARTUP' THEN 1 END) AS start_count_hr,
        COUNT(CASE WHEN met.event_code = 'SHUTDOWN' THEN 1 END) AS stop_count_hr,
        COUNT(CASE WHEN met.event_code IN ('BREAKDOWN', 'EMERGENCY_STOP') THEN 1 END) AS breakdown_count_hr,
        SUM(CASE WHEN met.event_code IN ('SHUTDOWN', 'BREAKDOWN', 'EMERGENCY_STOP', 'SETUP', 'IDLE') 
                 THEN EXTRACT(EPOCH FROM (COALESCE(me.ended_at, me.started_at + interval '1 hour') - me.started_at)) 
                 ELSE 0 END) AS downtime_sec_hr
    FROM machine_events me
    JOIN machine_event_types met ON me.event_type_id = met.event_type_id
    GROUP BY me.machine_id, date_trunc('hour', me.started_at)
),

-- 4. Пред-агрегируем производственные операции по часам
hourly_operations AS (
    SELECT 
        po.machine_id,
        date_trunc('hour', po.actual_start_at) AS hr,
        COUNT(po.production_operation_id) AS op_count_hr,
        SUM(EXTRACT(EPOCH FROM (po.actual_end_at - po.actual_start_at))) AS total_op_duration_hr
    FROM production_operations po
    GROUP BY po.machine_id, date_trunc('hour', po.actual_start_at)
),

-- 5. Соединяем все почасовые данные с сеткой времени через LEFT JOIN
joined_grid AS (
    SELECT 
        tg.*,
        hs.temp_hr, hs.vib_hr, hs.press_hr, hs.rpm_hr, hs.power_hr, hs.humidity_hr,
        COALESCE(he.start_count_hr, 0) AS start_count_hr,
        COALESCE(he.stop_count_hr, 0) AS stop_count_hr,
        COALESCE(he.breakdown_count_hr, 0) AS breakdown_count_hr,
        COALESCE(he.downtime_sec_hr, 0) AS downtime_sec_hr,
        COALESCE(ho.op_count_hr, 0) AS op_count_hr,
        COALESCE(ho.total_op_duration_hr, 0) AS total_op_duration_hr
    FROM time_grid tg
    LEFT JOIN hourly_sensors hs ON tg.machine_id = hs.machine_id AND tg.snapshot_time = hs.hr
    LEFT JOIN hourly_events he ON tg.machine_id = he.machine_id AND tg.snapshot_time = he.hr
    LEFT JOIN hourly_operations ho ON tg.machine_id = ho.machine_id AND tg.snapshot_time = ho.hr
),

-- 6. Рассчитываем скользящие окна (6 часов) и заглядываем вперед на 24 часа для таргета
analytics_calculated AS (
    SELECT 
        jg.machine_id,
        jg.machine_name,
        jg.machine_type,
        jg.snapshot_time,
        jg.commissioned_at,

        -- СЕНСОРЫ: Скользящее среднее (AVG) и стандартное отклонение (STDDEV) за последние 6 часов
        AVG(jg.temp_hr) OVER (PARTITION BY jg.machine_id ORDER BY jg.snapshot_time RANGE BETWEEN INTERVAL '5 hours' PRECEDING AND CURRENT ROW) AS temp_avg,
        STDDEV(jg.temp_hr) OVER (PARTITION BY jg.machine_id ORDER BY jg.snapshot_time RANGE BETWEEN INTERVAL '5 hours' PRECEDING AND CURRENT ROW) AS temp_std,
        
        AVG(jg.vib_hr) OVER (PARTITION BY jg.machine_id ORDER BY jg.snapshot_time RANGE BETWEEN INTERVAL '5 hours' PRECEDING AND CURRENT ROW) AS vib_avg,
        STDDEV(jg.vib_hr) OVER (PARTITION BY jg.machine_id ORDER BY jg.snapshot_time RANGE BETWEEN INTERVAL '5 hours' PRECEDING AND CURRENT ROW) AS vib_std,

        AVG(jg.press_hr) OVER (PARTITION BY jg.machine_id ORDER BY jg.snapshot_time RANGE BETWEEN INTERVAL '5 hours' PRECEDING AND CURRENT ROW) AS press_avg,
        STDDEV(jg.press_hr) OVER (PARTITION BY jg.machine_id ORDER BY jg.snapshot_time RANGE BETWEEN INTERVAL '5 hours' PRECEDING AND CURRENT ROW) AS press_std,

        AVG(jg.rpm_hr) OVER (PARTITION BY jg.machine_id ORDER BY jg.snapshot_time RANGE BETWEEN INTERVAL '5 hours' PRECEDING AND CURRENT ROW) AS rpm_avg,
        STDDEV(jg.rpm_hr) OVER (PARTITION BY jg.machine_id ORDER BY jg.snapshot_time RANGE BETWEEN INTERVAL '5 hours' PRECEDING AND CURRENT ROW) AS rpm_std,

        AVG(jg.power_hr) OVER (PARTITION BY jg.machine_id ORDER BY jg.snapshot_time RANGE BETWEEN INTERVAL '5 hours' PRECEDING AND CURRENT ROW) AS power_avg,
        STDDEV(jg.power_hr) OVER (PARTITION BY jg.machine_id ORDER BY jg.snapshot_time RANGE BETWEEN INTERVAL '5 hours' PRECEDING AND CURRENT ROW) AS power_std,

        AVG(jg.humidity_hr) OVER (PARTITION BY jg.machine_id ORDER BY jg.snapshot_time RANGE BETWEEN INTERVAL '5 hours' PRECEDING AND CURRENT ROW) AS humidity_avg,
        STDDEV(jg.humidity_hr) OVER (PARTITION BY jg.machine_id ORDER BY jg.snapshot_time RANGE BETWEEN INTERVAL '5 hours' PRECEDING AND CURRENT ROW) AS humidity_std,

        -- МАТЕМАТИЧЕСКИЙ ТРЕНД: Текущий час минус значение 5 часов назад
        jg.temp_hr - LAG(jg.temp_hr, 5) OVER (PARTITION BY jg.machine_id ORDER BY jg.snapshot_time) AS temp_trend,
        jg.vib_hr - LAG(jg.vib_hr, 5) OVER (PARTITION BY jg.machine_id ORDER BY jg.snapshot_time) AS vib_trend,
        jg.press_hr - LAG(jg.press_hr, 5) OVER (PARTITION BY jg.machine_id ORDER BY jg.snapshot_time) AS press_trend,
        jg.rpm_hr - LAG(jg.rpm_hr, 5) OVER (PARTITION BY jg.machine_id ORDER BY jg.snapshot_time) AS rpm_trend,
        jg.power_hr - LAG(jg.power_hr, 5) OVER (PARTITION BY jg.machine_id ORDER BY jg.snapshot_time) AS power_trend,
        jg.humidity_hr - LAG(jg.humidity_hr, 5) OVER (PARTITION BY jg.machine_id ORDER BY jg.snapshot_time) AS humidity_trend,

        -- СОБЫТИЯ И ОПЕРАЦИИ: Суммы за 6 часов
        SUM(jg.start_count_hr) OVER (PARTITION BY jg.machine_id ORDER BY jg.snapshot_time RANGE BETWEEN INTERVAL '5 hours' PRECEDING AND CURRENT ROW) AS start_count,
        SUM(jg.stop_count_hr) OVER (PARTITION BY jg.machine_id ORDER BY jg.snapshot_time RANGE BETWEEN INTERVAL '5 hours' PRECEDING AND CURRENT ROW) AS stop_count,
        SUM(jg.downtime_sec_hr) OVER (PARTITION BY jg.machine_id ORDER BY jg.snapshot_time RANGE BETWEEN INTERVAL '5 hours' PRECEDING AND CURRENT ROW) AS downtime_seconds,
        SUM(jg.breakdown_count_hr) OVER (PARTITION BY jg.machine_id ORDER BY jg.snapshot_time RANGE BETWEEN INTERVAL '5 hours' PRECEDING AND CURRENT ROW) AS breakdown_count_hist,
        SUM(jg.op_count_hr) OVER (PARTITION BY jg.machine_id ORDER BY jg.snapshot_time RANGE BETWEEN INTERVAL '5 hours' PRECEDING AND CURRENT ROW) AS operation_count,
        
        -- Средняя длительность операций в окне
        CASE 
            WHEN SUM(jg.op_count_hr) OVER (PARTITION BY jg.machine_id ORDER BY jg.snapshot_time RANGE BETWEEN INTERVAL '5 hours' PRECEDING AND CURRENT ROW) > 0 
            THEN (SUM(jg.total_op_duration_hr) OVER (PARTITION BY jg.machine_id ORDER BY jg.snapshot_time RANGE BETWEEN INTERVAL '5 hours' PRECEDING AND CURRENT ROW)) / 
                 (SUM(jg.op_count_hr) OVER (PARTITION BY jg.machine_id ORDER BY jg.snapshot_time RANGE BETWEEN INTERVAL '5 hours' PRECEDING AND CURRENT ROW))
            ELSE 0 
        END AS avg_op_duration_sec,

        -- ДИНАМИЧЕСКИЙ ВОЗРАСТ ОБОРУДОВАНИЯ
        EXTRACT(DAY FROM (jg.snapshot_time - jg.commissioned_at)) AS age_days,

        -- ДИНАМИЧЕСКОЕ ВРЕМЯ ПОСЛЕДНЕГО ТО
        (SELECT MAX(mwo.completed_at) 
         FROM maintenance_work_orders mwo 
         WHERE mwo.machine_id = jg.machine_id 
           AND mwo.status = 'COMPLETED'
           AND mwo.completed_at <= jg.snapshot_time) AS last_maint_time,

        -- ЦЕЛЕВАЯ МЕТКА: Равна 1, если в следующие 24 часа случится BREAKDOWN или EMERGENCY_STOP
        CASE 
            WHEN SUM(jg.breakdown_count_hr) OVER (PARTITION BY jg.machine_id ORDER BY jg.snapshot_time RANGE BETWEEN INTERVAL '1 hour' FOLLOWING AND INTERVAL '24 hours' FOLLOWING) > 0 
            THEN 1 
            ELSE 0 
        END AS failure_next_24h

    FROM joined_grid jg
)
-- 7. Финальный расчет дней с момента последнего ТО
SELECT 
    machine_id,
    machine_name,
    machine_type,
    snapshot_time,
    temp_avg, temp_std, temp_trend,
    vib_avg, vib_std, vib_trend,
    press_avg, press_std, press_trend,
    rpm_avg, rpm_std, rpm_trend,
    power_avg, power_std, power_trend,
    humidity_avg, humidity_std, humidity_trend,
    start_count,
    stop_count,
    downtime_seconds,
    breakdown_count_hist,
    operation_count,
    avg_op_duration_sec,
    age_days,
    COALESCE(EXTRACT(DAY FROM (snapshot_time - last_maint_time)), 10000) AS days_since_maintenance,
    failure_next_24h
FROM analytics_calculated;
