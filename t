process.env.NODE_TLS_REJECT_UNAUTHORIZED = '0'; 

const express = require('express');
const dotenv = require('dotenv');

dotenv.config({ path: '.env.local' });

const app = express();
const PORT = process.env.PORT || 3000;

app.use(express.json());

app.get('/api/sync-demands', async (req, res) => {
    try {
        const username = process.env.ODATA_USER;
        const password = process.env.ODATA_PASS;
        const baseUrl = process.env.ODATA_BASE_URL;

        if (!username || !password || !baseUrl) {
            return res.status(500).json({ error: 'بيانات الاتصال غير مكتملة في .env.local' });
        }

        const cleanBaseUrl = baseUrl.replace(/\/+$/, '');

        const filter = "contains(DisplayLabel,'Rahabah')";
        const targetedUrl =
            `${cleanBaseUrl}/Request?$select=Id,DisplayLabel,Status,Priority,CreatedDate` +
            `&$filter=${encodeURIComponent(filter)}`;

        console.log('المسار المستهدف:', targetedUrl);

        const credentials = Buffer.from(`${username}:${password}`).toString('base64');

        const response = await fetch(targetedUrl, {
            method: 'GET',
            headers: {
                'Accept': 'application/json',
                'Authorization': `Basic ${credentials}`
            }
        });

        if (!response.ok) {
            const body = await response.text();
            console.error(`SMAX Error Status: ${response.status}`, body);
            return res.status(response.status).json({ error: 'فشل جلب البيانات من SMAX' });
        }

        const data = await response.json();
        res.json(data);

    } catch (error) {
        console.error('Server Error:', error.message, error.cause || '');
        res.status(500).json({ error: 'خطأ في السيرفر الوسيط' });
    }
});

app.listen(PORT, () => {
    console.log(`[SECURE SERVER] Running on http://localhost:${PORT}`);
});
